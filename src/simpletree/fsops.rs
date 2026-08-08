//! Filesystem operations executed in the daemon instead of in Vim.
//!
//! Every byte of a copy used to move through Vimscript on the main thread:
//! `readblob` in 1 MB chunks, one `writefile` per chunk, one `readdir` per
//! directory.  Pasting a `target/` or `node_modules/` froze the editor — no
//! redraw, no CTRL-C, no progress — for as long as the copy took.  The daemon
//! is idle during exactly that window, so the work belongs here.
//!
//! What does *not* move here is policy.  Workspace containment, modified-buffer
//! refusal, the conflict prompts and the post-prompt re-validation all stay in
//! `autoload/simpletree.vim`, because they depend on editor state the daemon
//! cannot see.  This module receives an already-approved (src, dst) pair and is
//! responsible for one thing: performing the transfer with the same staging
//! discipline the Vim implementation uses, so a failure can never leave the
//! destination half-written.
//!
//! The discipline, unchanged from the Vim original:
//!   1. write the new content to a `.simpletree-staged-*` sibling of the target
//!      (same directory, therefore the same filesystem, therefore an atomic
//!      install is possible),
//!   2. rename any pre-existing target aside to a `.simpletree-backup-*` sibling,
//!   3. rename the staged copy into place,
//!   4. delete the backup — or restore it if step 3 failed.
//!
//! A crash at any point leaves either the old target or the backup, never a
//! truncated file.

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
};
use tokio_util::sync::CancellationToken;

/// Guards against a pathological tree (or a directory hard-link cycle on the
/// filesystems that permit one) turning a copy into an unbounded recursion.
/// Deeper than any real project; shallow enough that the recursion cannot blow
/// the blocking thread's stack.
const MAX_COPY_DEPTH: usize = 64;

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum FsOpKind {
    Copy,
    Move,
    Remove,
}

impl FsOpKind {
    fn needs_destination(self) -> bool {
        !matches!(self, FsOpKind::Remove)
    }
}

/// Mirrors the dict the Vim `CopyPathSafely`/`MovePathSafely` helpers return, so
/// the frontend's success handling is identical on both paths.
#[derive(Debug, Default, Serialize)]
pub struct FsOpOutcome {
    /// Copy/move: the destination now holds the new content. Remove: it is gone.
    pub installed: bool,
    /// Only a same-filesystem rename removes the source; a cross-device fallback
    /// installs a complete copy and deliberately keeps it.
    pub source_removed: bool,
    /// Non-empty when the displaced old target could not be cleaned up; the
    /// frontend surfaces the path so nothing is silently orphaned.
    pub backup: String,
    /// Why it failed, empty on success.
    pub message: String,
}

impl FsOpOutcome {
    fn failed(message: impl Into<String>) -> Self {
        FsOpOutcome {
            message: message.into(),
            ..Default::default()
        }
    }
}

/// Rejects the pairs that can destroy data no matter how carefully the transfer
/// itself is staged. The frontend checks these too; a daemon that trusts its
/// caller here is one malformed request away from deleting a project.
fn validate(kind: FsOpKind, src: &Path, dst: &Path) -> Result<()> {
    if src.as_os_str().is_empty() {
        bail!("missing source path");
    }
    if !src.is_absolute() {
        bail!("source path must be absolute");
    }
    if fs::symlink_metadata(src).is_err() {
        bail!("source does not exist: {}", src.display());
    }
    if !kind.needs_destination() {
        return Ok(());
    }
    if dst.as_os_str().is_empty() {
        bail!("missing destination path");
    }
    if !dst.is_absolute() {
        bail!("destination path must be absolute");
    }
    if src == dst {
        bail!("source and destination are the same path");
    }
    // Copying a directory into its own subtree is an infinite regress: the
    // recursion keeps finding the growing destination inside the source.
    if dst.starts_with(src) {
        bail!("destination is inside the source");
    }
    match dst.parent() {
        Some(parent) if parent.is_dir() => Ok(()),
        _ => bail!("destination directory does not exist"),
    }
}

/// A staging/backup name beside `target`, on the same filesystem so the install
/// can be a rename. The original leaf name is deliberately not embedded: a
/// legitimate target close to NAME_MAX must still be able to produce one.
fn unique_sibling(target: &Path, tag: &str) -> Result<PathBuf> {
    let Some(parent) = target.parent() else {
        bail!("path has no parent directory: {}", target.display());
    };
    let seed = format!(
        ".simpletree-{tag}-{:x}-{:x}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    );
    let mut candidate = parent.join(&seed);
    let mut index = 0_u32;
    while fs::symlink_metadata(&candidate).is_ok() {
        index += 1;
        if index > 10_000 {
            bail!("could not allocate a staging name in {}", parent.display());
        }
        candidate = parent.join(format!("{seed}-{index}"));
    }
    Ok(candidate)
}

fn cancelled(cancel: &CancellationToken) -> Result<()> {
    if cancel.is_cancelled() {
        bail!("canceled");
    }
    Ok(())
}

#[cfg(unix)]
fn copy_symlink(src: &Path, dst: &Path) -> std::io::Result<()> {
    std::os::unix::fs::symlink(fs::read_link(src)?, dst)
}

#[cfg(not(unix))]
fn copy_symlink(_src: &Path, _dst: &Path) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "copying symbolic links is not supported on this platform",
    ))
}

/// Recursive copy that never follows a symlink: a link is recreated as a link,
/// which is what makes a copied tree equal to its source rather than an
/// unrolled, possibly infinite, expansion of it.
fn copy_tree(src: &Path, dst: &Path, depth: usize, cancel: &CancellationToken) -> Result<()> {
    cancelled(cancel)?;
    if depth > MAX_COPY_DEPTH {
        bail!(
            "directory nesting exceeds {MAX_COPY_DEPTH} levels at {}",
            src.display()
        );
    }
    let meta = fs::symlink_metadata(src)?;
    let file_type = meta.file_type();

    if file_type.is_symlink() {
        copy_symlink(src, dst)?;
        return Ok(());
    }
    if file_type.is_file() {
        fs::copy(src, dst)?;
        return Ok(());
    }
    if !file_type.is_dir() {
        bail!("unsupported filesystem entry: {}", src.display());
    }

    fs::create_dir(dst)?;
    // Permissions are applied after the children so that a read-only source
    // directory does not lock the copy out of its own destination mid-walk.
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        copy_tree(
            &entry.path(),
            &dst.join(entry.file_name()),
            depth + 1,
            cancel,
        )?;
    }
    if let Ok(permissions) = fs::metadata(src).map(|m| m.permissions()) {
        let _ = fs::set_permissions(dst, permissions);
    }
    Ok(())
}

/// Removes a path whatever it is. `remove_dir_all` refuses a symlink that points
/// at a directory, and following one would delete outside the tree, so links are
/// always unlinked rather than traversed.
fn remove_tree(path: &Path) -> Result<()> {
    let Ok(meta) = fs::symlink_metadata(path) else {
        return Ok(()); // Already gone: the caller's goal is satisfied.
    };
    if meta.file_type().is_dir() {
        fs::remove_dir_all(path)?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn best_effort_remove(path: &Path) {
    let _ = remove_tree(path);
}

/// Copy `src` over `dst` without ever leaving `dst` in a partial state.
fn copy_safely(src: &Path, dst: &Path, cancel: &CancellationToken) -> FsOpOutcome {
    let staged = match unique_sibling(dst, "staged") {
        Ok(staged) => staged,
        Err(error) => return FsOpOutcome::failed(error.to_string()),
    };
    if let Err(error) = copy_tree(src, &staged, 0, cancel) {
        best_effort_remove(&staged);
        return FsOpOutcome::failed(error.to_string());
    }

    let mut backup = PathBuf::new();
    if fs::symlink_metadata(dst).is_ok() {
        let candidate = match unique_sibling(dst, "backup") {
            Ok(candidate) => candidate,
            Err(error) => {
                best_effort_remove(&staged);
                return FsOpOutcome::failed(error.to_string());
            }
        };
        if let Err(error) = fs::rename(dst, &candidate) {
            best_effort_remove(&staged);
            return FsOpOutcome::failed(format!("could not displace the old target: {error}"));
        }
        backup = candidate;
    }

    if let Err(error) = fs::rename(&staged, dst) {
        best_effort_remove(&staged);
        if !backup.as_os_str().is_empty() && fs::rename(&backup, dst).is_err() {
            return FsOpOutcome {
                backup: backup.to_string_lossy().into_owned(),
                message: format!("install failed and rollback failed: {error}"),
                ..Default::default()
            };
        }
        return FsOpOutcome::failed(format!("could not install the copy: {error}"));
    }

    finish(backup)
}

/// Same-filesystem rename first: it is atomic and, unlike copy-then-delete, has
/// no window in which the source can change between the two halves. The
/// cross-device fallback installs a complete copy and keeps the source, exactly
/// as the Vim implementation does, because deleting it would be that race.
fn move_safely(src: &Path, dst: &Path, cancel: &CancellationToken) -> FsOpOutcome {
    let mut backup = PathBuf::new();
    if fs::symlink_metadata(dst).is_ok() {
        let candidate = match unique_sibling(dst, "backup") {
            Ok(candidate) => candidate,
            Err(error) => return FsOpOutcome::failed(error.to_string()),
        };
        if fs::rename(dst, &candidate).is_err() {
            return FsOpOutcome::failed("could not displace the old target");
        }
        backup = candidate;
    }

    if fs::rename(src, dst).is_ok() {
        let mut outcome = finish(backup);
        outcome.source_removed = true;
        return outcome;
    }

    if !backup.as_os_str().is_empty() && fs::rename(&backup, dst).is_err() {
        return FsOpOutcome {
            backup: backup.to_string_lossy().into_owned(),
            message: "move rollback failed".to_owned(),
            ..Default::default()
        };
    }

    let mut outcome = copy_safely(src, dst, cancel);
    outcome.source_removed = false;
    outcome
}

/// Retire the displaced target. Failing to delete it is not a failed operation —
/// the new content is installed — but the leftover must be reported, never
/// silently orphaned in the user's project.
fn finish(backup: PathBuf) -> FsOpOutcome {
    let mut outcome = FsOpOutcome {
        installed: true,
        ..Default::default()
    };
    if !backup.as_os_str().is_empty() && remove_tree(&backup).is_err() {
        outcome.backup = backup.to_string_lossy().into_owned();
    }
    outcome
}

/// Blocking entry point. Runs on `spawn_blocking` under the daemon's scan
/// semaphore, so a huge copy cannot starve directory listing.
pub fn run(kind: FsOpKind, src: &Path, dst: &Path, cancel: &CancellationToken) -> FsOpOutcome {
    if let Err(error) = validate(kind, src, dst) {
        return FsOpOutcome::failed(error.to_string());
    }
    match kind {
        FsOpKind::Copy => copy_safely(src, dst, cancel),
        FsOpKind::Move => move_safely(src, dst, cancel),
        FsOpKind::Remove => match remove_tree(src) {
            Ok(()) => FsOpOutcome {
                installed: true,
                source_removed: true,
                ..Default::default()
            },
            Err(error) => FsOpOutcome::failed(error.to_string()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cancel() -> CancellationToken {
        CancellationToken::new()
    }

    #[test]
    fn a_failed_copy_leaves_the_old_target_untouched() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src");
        let dst = dir.path().join("dst");
        fs::write(&dst, b"original").unwrap();

        // The source does not exist, so validation refuses before anything moves.
        let outcome = run(FsOpKind::Copy, &src, &dst, &cancel());
        assert!(!outcome.installed);
        assert!(!outcome.message.is_empty());
        assert_eq!(fs::read(&dst).unwrap(), b"original");
    }

    #[test]
    fn copy_replaces_the_target_and_keeps_the_source() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src");
        let dst = dir.path().join("dst");
        fs::write(&src, b"new").unwrap();
        fs::write(&dst, b"old").unwrap();

        let outcome = run(FsOpKind::Copy, &src, &dst, &cancel());
        assert!(outcome.installed, "{}", outcome.message);
        assert!(!outcome.source_removed);
        assert!(outcome.backup.is_empty());
        assert_eq!(fs::read(&dst).unwrap(), b"new");
        assert_eq!(fs::read(&src).unwrap(), b"new");
        // No staging or backup sibling survives a successful install.
        let leftovers: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|name| name.starts_with(".simpletree-"))
            .collect();
        assert!(leftovers.is_empty(), "leftovers: {leftovers:?}");
    }

    #[test]
    fn a_directory_copy_recreates_symlinks_rather_than_following_them() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("tree");
        fs::create_dir_all(src.join("nested")).unwrap();
        fs::write(src.join("nested/file.txt"), b"leaf").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("nested/file.txt", src.join("link")).unwrap();

        let dst = dir.path().join("copy");
        let outcome = run(FsOpKind::Copy, &src, &dst, &cancel());
        assert!(outcome.installed, "{}", outcome.message);
        assert_eq!(fs::read(dst.join("nested/file.txt")).unwrap(), b"leaf");
        #[cfg(unix)]
        assert!(
            fs::symlink_metadata(dst.join("link"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }

    #[test]
    fn move_renames_and_reports_the_source_gone() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src.txt");
        let dst = dir.path().join("moved.txt");
        fs::write(&src, b"payload").unwrap();

        let outcome = run(FsOpKind::Move, &src, &dst, &cancel());
        assert!(outcome.installed, "{}", outcome.message);
        assert!(outcome.source_removed);
        assert!(fs::symlink_metadata(&src).is_err());
        assert_eq!(fs::read(&dst).unwrap(), b"payload");
    }

    #[test]
    fn remove_deletes_a_tree_and_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let victim = dir.path().join("victim");
        fs::create_dir_all(victim.join("deep")).unwrap();
        fs::write(victim.join("deep/f"), b"x").unwrap();

        assert!(run(FsOpKind::Remove, &victim, Path::new(""), &cancel()).installed);
        assert!(!victim.exists());
        // A second remove of a vanished path is refused by validation rather
        // than reported as a delete that happened.
        let again = run(FsOpKind::Remove, &victim, Path::new(""), &cancel());
        assert!(!again.installed);
    }

    #[test]
    fn copying_a_directory_into_itself_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("tree");
        fs::create_dir_all(&src).unwrap();
        let dst = src.join("inner");
        let outcome = run(FsOpKind::Copy, &src, &dst, &cancel());
        assert!(!outcome.installed);
        assert!(outcome.message.contains("inside the source"));
    }

    #[test]
    fn a_cancelled_copy_installs_nothing_and_leaves_no_staging_files() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("tree");
        fs::create_dir_all(&src).unwrap();
        fs::write(src.join("a"), b"a").unwrap();
        let dst = dir.path().join("copy");

        let token = cancel();
        token.cancel();
        let outcome = run(FsOpKind::Copy, &src, &dst, &token);
        assert!(!outcome.installed);
        assert!(!dst.exists());
        let leftovers: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|name| name.starts_with(".simpletree-"))
            .collect();
        assert!(leftovers.is_empty(), "leftovers: {leftovers:?}");
    }
}
