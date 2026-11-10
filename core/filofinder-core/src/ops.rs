//! File operations with the safety rules of PLAN §5:
//! - never overwrite: every placement uses `renamex_np(RENAME_EXCL)`;
//! - copies are written under a hidden partial name, then renamed into
//!   place, so a crash never leaves a half-copied file under the real name;
//! - same-volume moves are one atomic `rename`; cross-volume moves copy,
//!   verify, and only then delete the source;
//! - a folder can never be moved or copied into itself.

use std::ffi::{CStr, CString};
use std::fs;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

#[derive(Debug)]
pub enum OpError {
    /// The destination name is taken; nothing was changed.
    Exists(PathBuf),
    /// Destination is the source itself or inside it.
    IntoItself(PathBuf),
    InvalidName(String),
    /// The caller asked to stop. Nothing was left under the destination name.
    Cancelled,
    Io(PathBuf, io::Error),
}

impl std::fmt::Display for OpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Exists(p) => write!(f, "“{}” already exists", name_of(p)),
            Self::IntoItself(p) => write!(f, "“{}” can’t be moved or copied into itself", name_of(p)),
            Self::InvalidName(n) => write!(f, "“{n}” isn’t a valid name"),
            Self::Cancelled => write!(f, "Cancelled"),
            Self::Io(p, e) => write!(f, "{}: {e}", p.display()),
        }
    }
}

impl std::error::Error for OpError {}

pub type OpResult<T> = Result<T, OpError>;

fn name_of(p: &Path) -> String {
    p.file_name().map_or_else(|| p.display().to_string(), |n| n.to_string_lossy().into_owned())
}

fn cstr(p: &Path) -> OpResult<CString> {
    CString::new(p.as_os_str().as_bytes()).map_err(|_| OpError::InvalidName(p.display().to_string()))
}

fn io_err(p: &Path) -> impl FnOnce(io::Error) -> OpError + '_ {
    move |e| OpError::Io(p.to_path_buf(), e)
}

/// Validates a single path component typed by the user.
pub fn validate_name(name: &str) -> OpResult<()> {
    let bad = name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains('\0') || name.len() > 255;
    if bad { Err(OpError::InvalidName(name.to_string())) } else { Ok(()) }
}

/// Atomic rename that fails instead of replacing an existing item.
fn rename_excl(from: &Path, to: &Path) -> OpResult<()> {
    let (f, t) = (cstr(from)?, cstr(to)?);
    // SAFETY: valid NUL-terminated paths.
    let rc = unsafe { libc::renamex_np(f.as_ptr(), t.as_ptr(), libc::RENAME_EXCL) };
    if rc == 0 {
        return Ok(());
    }
    let e = io::Error::last_os_error();
    if e.raw_os_error() == Some(libc::EEXIST) { Err(OpError::Exists(to.to_path_buf())) } else { Err(OpError::Io(to.to_path_buf(), e)) }
}

fn same_device(a: &Path, b: &Path) -> OpResult<bool> {
    let da = fs::symlink_metadata(a).map_err(io_err(a))?.dev();
    let db = fs::metadata(b).map_err(io_err(b))?.dev();
    Ok(da == db)
}

/// Refuses `dest_dir` == `src` or anywhere inside `src`.
fn check_not_into_itself(src: &Path, dest_dir: &Path) -> OpResult<()> {
    let s = fs::canonicalize(src).map_err(io_err(src))?;
    let d = fs::canonicalize(dest_dir).map_err(io_err(dest_dir))?;
    if d == s || d.starts_with(&s) { Err(OpError::IntoItself(src.to_path_buf())) } else { Ok(()) }
}

/// Finder-style free name: "photo.jpg" → "photo 2.jpg" → "photo 3.jpg".
pub fn unique_name(dir: &Path, name: &str) -> String {
    if fs::symlink_metadata(dir.join(name)).is_err() {
        return name.to_string();
    }
    let (base, ext) = match name.rfind('.') {
        Some(i) if i > 0 => (&name[..i], &name[i..]),
        _ => (name, ""),
    };
    (2..)
        .map(|n| format!("{base} {n}{ext}"))
        .find(|candidate| fs::symlink_metadata(dir.join(candidate)).is_err())
        .expect("unbounded")
}

/// Hidden temporary name used while a copy is in flight.
fn partial_name(name: &str) -> String {
    format!(".{name}.ffpartial-{}", std::process::id())
}

const COPY_FLAGS: libc::copyfile_flags_t = libc::COPYFILE_METADATA
    | libc::COPYFILE_DATA
    | libc::COPYFILE_RECURSIVE
    | libc::COPYFILE_CLONE
    | libc::COPYFILE_NOFOLLOW
    | libc::COPYFILE_DATA_SPARSE;

/// Copies `src` into `dest_dir` as `name`. Folders are copied recursively;
/// metadata (xattrs, ACLs, tags, dates) is kept; same-volume copies use APFS
/// clones (instant, no extra space). Symlinks are copied as links.
pub fn copy_item(src: &Path, dest_dir: &Path, name: &str) -> OpResult<PathBuf> {
    copy_item_reporting(src, dest_dir, name, &|_, _, _| true)
}

/// Same as [`copy_item`], calling `report(copied, total, current_file)` on this thread.
/// `total == 0` means the size is still being measured. Return `false` to cancel;
/// a partial destination is removed and the source is left in place.
///
/// `copyfile` does not invoke byte callbacks when an APFS clone succeeds, so a
/// same-volume clone jumps to the full size. Cross-volume copies report bytes.
pub fn copy_item_reporting(
    src: &Path,
    dest_dir: &Path,
    name: &str,
    report: &dyn Fn(u64, u64, &str) -> bool,
) -> OpResult<PathBuf> {
    validate_name(name)?;
    check_not_into_itself(src, dest_dir)?;
    let target = dest_dir.join(name);
    if fs::symlink_metadata(&target).is_ok() {
        return Err(OpError::Exists(target));
    }
    let partial = dest_dir.join(partial_name(name));
    let _ = remove_any(&partial); // stale leftover from a crash

    let mut ctx = ProgressCtx::new(report, &name_of(src));
    if !measure(src, &mut ctx) {
        return Err(OpError::Cancelled);
    }
    // Size is known: 0 of N, still before the first byte is written.
    ctx.current_display = name_of(src);
    if !ctx.emit(0, true) {
        return Err(OpError::Cancelled);
    }

    let state = unsafe { libc::copyfile_state_alloc() };
    if state.is_null() {
        return Err(OpError::Io(src.to_path_buf(), io::Error::other("couldn’t allocate copy state")));
    }
    // Frees the state on every exit, including `?` below. The context is not owned by the state.
    let _state = CopyState(state);
    let (s, p) = (cstr(src)?, cstr(&partial)?);
    // SAFETY: `s` and `p` are NUL-terminated paths. The context pointer is only
    // dereferenced by `status_cb` while `copyfile` is on the stack, before `ctx` is used again.
    let rc = unsafe {
        let ctx_ptr: *mut ProgressCtx<'_> = &mut ctx;
        libc::copyfile_state_set(
            state,
            libc::COPYFILE_STATE_STATUS_CB as u32,
            status_cb as *const libc::c_void,
        );
        libc::copyfile_state_set(
            state,
            libc::COPYFILE_STATE_STATUS_CTX as u32,
            ctx_ptr.cast::<libc::c_void>(),
        );
        libc::copyfile(s.as_ptr(), p.as_ptr(), state, COPY_FLAGS)
    };
    if rc != 0 || ctx.cancelled {
        let _ = remove_any(&partial);
        if ctx.cancelled {
            return Err(OpError::Cancelled);
        }
        return Err(OpError::Io(src.to_path_buf(), io::Error::last_os_error()));
    }
    if let Err(e) = rename_excl(&partial, &target) {
        let _ = remove_any(&partial);
        return Err(e);
    }
    ctx.finished = ctx.total;
    ctx.current_display = name_of(src);
    let _ = ctx.emit(0, true);
    Ok(target)
}

/// Moves `src` into `dest_dir` as `name`.
pub fn move_item(src: &Path, dest_dir: &Path, name: &str) -> OpResult<PathBuf> {
    move_item_reporting(src, dest_dir, name, &|_, _, _| true)
}

/// Same as [`move_item`]. A same-volume move is one rename and reports `(1, 1)` when it
/// finishes. A cross-volume move reports copy progress, then deletes the source.
pub fn move_item_reporting(
    src: &Path,
    dest_dir: &Path,
    name: &str,
    report: &dyn Fn(u64, u64, &str) -> bool,
) -> OpResult<PathBuf> {
    validate_name(name)?;
    check_not_into_itself(src, dest_dir)?;
    let target = dest_dir.join(name);
    if same_device(src, dest_dir)? {
        rename_excl(src, &target)?;
        let _ = report(1, 1, &name_of(&target));
        return Ok(target);
    }
    // Different volume: copy fully, verify, then remove the source.
    let copied = copy_item_reporting(src, dest_dir, name, report)?;
    if !same_content_shape(src, &copied) {
        let _ = remove_any(&copied);
        return Err(OpError::Io(src.to_path_buf(), io::Error::other("copy verification failed; original kept")));
    }
    remove_any(src).map_err(io_err(src))?;
    Ok(copied)
}

struct CopyState(libc::copyfile_state_t);

impl Drop for CopyState {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { libc::copyfile_state_free(self.0) };
        }
    }
}

/// Byte progress for one `copyfile` call. `finished` is bytes of files already done;
/// `emit(in_file)` reports `finished + in_file`, capped at the measured total.
struct ProgressCtx<'a> {
    report: &'a dyn Fn(u64, u64, &str) -> bool,
    total: u64,
    finished: u64,
    /// Logical size of the file currently being copied (0 for a clone until FINISH).
    current_len: u64,
    last_in_file: u64,
    current_display: String,
    last_emit: Instant,
    cancelled: bool,
}

impl<'a> ProgressCtx<'a> {
    fn new(report: &'a dyn Fn(u64, u64, &str) -> bool, display: &str) -> Self {
        Self {
            report,
            total: 0,
            finished: 0,
            current_len: 0,
            last_in_file: 0,
            current_display: display.to_string(),
            // The first emit should not be throttled.
            last_emit: Instant::now() - Duration::from_secs(1),
            cancelled: false,
        }
    }

    /// Reports progress. `in_file` is bytes of the current file on top of `finished`.
    fn emit(&mut self, in_file: u64, force: bool) -> bool {
        if self.cancelled {
            return false;
        }
        if !force && self.last_emit.elapsed() < Duration::from_millis(100) {
            return true;
        }
        self.last_emit = Instant::now();
        let mut copied = self.finished.saturating_add(in_file);
        if self.total > 0 {
            copied = copied.min(self.total);
        }
        let ok = (self.report)(copied, self.total, &self.current_display);
        if !ok {
            self.cancelled = true;
        }
        ok
    }
}

/// Logical size, not following symlinks (the copy does not follow them either).
fn measure(path: &Path, ctx: &mut ProgressCtx<'_>) -> bool {
    fn walk(path: &Path, ctx: &mut ProgressCtx<'_>, acc: &mut u64) -> bool {
        if ctx.cancelled {
            return false;
        }
        if ctx.last_emit.elapsed() >= Duration::from_millis(100) {
            ctx.current_display = path.to_string_lossy().into_owned();
            if !ctx.emit(0, true) {
                return false;
            }
        }
        let Ok(meta) = fs::symlink_metadata(path) else { return true };
        let ft = meta.file_type();
        if ft.is_symlink() || !ft.is_dir() {
            *acc = acc.saturating_add(meta.len());
            return true;
        }
        let Ok(entries) = fs::read_dir(path) else { return true };
        for entry in entries.flatten() {
            if !walk(&entry.path(), ctx, acc) {
                return false;
            }
        }
        true
    }
    ctx.current_display = path.to_string_lossy().into_owned();
    if !ctx.emit(0, true) {
        return false;
    }
    let mut acc = 0u64;
    if !walk(path, ctx, &mut acc) {
        return false;
    }
    ctx.total = acc;
    true
}

fn file_len(path: &Path) -> u64 {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() || meta.is_file() => meta.len(),
        _ => 0,
    }
}

fn c_path(ptr: *const libc::c_char) -> Option<PathBuf> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: copyfile passes a NUL-terminated path, or NULL (handled above).
    let bytes = unsafe { CStr::from_ptr(ptr) }.to_bytes();
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(bytes)))
}

fn copied_bytes(state: libc::copyfile_state_t) -> u64 {
    let mut n: libc::off_t = 0;
    // SAFETY: `n` is the off_t COPYFILE_STATE_COPIED asks for.
    let rc = unsafe {
        libc::copyfile_state_get(
            state,
            libc::COPYFILE_STATE_COPIED as u32,
            (&mut n as *mut libc::off_t).cast::<libc::c_void>(),
        )
    };
    if rc == 0 && n > 0 { n as u64 } else { 0 }
}

/// copyfile status callback. `COPYFILE_QUIT` on a real error preserves the failure
/// (returning CONTINUE would retry a bad write, or skip a failed child). User cancel
/// sets `ctx.cancelled` and also returns QUIT.
extern "C" fn status_cb(
    what: libc::c_int,
    stage: libc::c_int,
    state: libc::copyfile_state_t,
    src: *const libc::c_char,
    _dst: *const libc::c_char,
    raw: *mut libc::c_void,
) -> libc::c_int {
    if raw.is_null() {
        return libc::COPYFILE_CONTINUE;
    }
    // SAFETY: the pointer is the ProgressCtx on copy_item_reporting's stack and is only
    // dereferenced while that frame is live (copyfile calls us synchronously). The 'static
    // lifetime is a stand-in so this non-generic C callback can name the type; the report
    // closure is not stored past the call.
    let ctx = unsafe { &mut *raw.cast::<ProgressCtx<'static>>() };
    if ctx.cancelled {
        return libc::COPYFILE_QUIT;
    }
    // An extended-attribute error is reported to the callback and, with no callback,
    // is often ignored (quarantine) or warned. QUIT here would fail a copy that used
    // to succeed, and CONTINUE on a data error would retry the write forever.
    if stage == libc::COPYFILE_ERR {
        return if what == libc::COPYFILE_COPY_XATTR { libc::COPYFILE_CONTINUE } else { libc::COPYFILE_QUIT };
    }
    if what == libc::COPYFILE_RECURSE_FILE && stage == libc::COPYFILE_START {
        if let Some(path) = c_path(src) {
            ctx.current_display = path.to_string_lossy().into_owned();
            ctx.current_len = file_len(&path);
        }
        ctx.last_in_file = 0;
        return if ctx.emit(0, true) { libc::COPYFILE_CONTINUE } else { libc::COPYFILE_QUIT };
    }
    if what == libc::COPYFILE_COPY_DATA && stage == libc::COPYFILE_PROGRESS {
        let n = copied_bytes(state);
        ctx.last_in_file = n;
        if ctx.current_display.is_empty() {
            if let Some(path) = c_path(src) {
                ctx.current_display = path.to_string_lossy().into_owned();
                ctx.current_len = file_len(&path);
            }
        }
        return if ctx.emit(n, false) { libc::COPYFILE_CONTINUE } else { libc::COPYFILE_QUIT };
    }
    if what == libc::COPYFILE_RECURSE_FILE && stage == libc::COPYFILE_FINISH {
        let add = ctx.current_len.max(ctx.last_in_file);
        ctx.finished = ctx.finished.saturating_add(add);
        ctx.current_len = 0;
        ctx.last_in_file = 0;
        return if ctx.emit(0, true) { libc::COPYFILE_CONTINUE } else { libc::COPYFILE_QUIT };
    }
    libc::COPYFILE_CONTINUE
}

/// Cheap verification: same kind, and for files the same byte size; for
/// folders the same number of entries at every level.
fn same_content_shape(a: &Path, b: &Path) -> bool {
    let (Ok(ma), Ok(mb)) = (fs::symlink_metadata(a), fs::symlink_metadata(b)) else { return false };
    if ma.file_type().is_dir() != mb.file_type().is_dir() {
        return false;
    }
    if !ma.file_type().is_dir() {
        return ma.file_type().is_symlink() || ma.len() == mb.len();
    }
    let names = |p: &Path| -> Option<Vec<std::ffi::OsString>> {
        let mut v: Vec<_> = fs::read_dir(p).ok()?.filter_map(|e| e.ok().map(|e| e.file_name())).collect();
        v.sort();
        Some(v)
    };
    match (names(a), names(b)) {
        (Some(na), Some(nb)) if na == nb => na.iter().all(|n| same_content_shape(&a.join(n), &b.join(n))),
        _ => false,
    }
}

/// Renames in place. Case-only renames ("a.txt" → "A.txt") are allowed on
/// case-insensitive volumes, where the new name "already exists".
pub fn rename_item(path: &Path, new_name: &str) -> OpResult<PathBuf> {
    validate_name(new_name)?;
    let dir = path.parent().unwrap_or(Path::new("/"));
    let target = dir.join(new_name);
    let old = name_of(path);
    if old == new_name {
        return Ok(target);
    }
    if old.to_lowercase() == new_name.to_lowercase() {
        fs::rename(path, &target).map_err(io_err(path))?;
        return Ok(target);
    }
    rename_excl(path, &target)?;
    Ok(target)
}

/// Creates "untitled folder" (or "untitled folder 2", …) in `dir`.
pub fn new_folder(dir: &Path) -> OpResult<PathBuf> {
    let name = unique_name(dir, "untitled folder");
    let path = dir.join(name);
    fs::create_dir(&path).map_err(io_err(&path))?;
    Ok(path)
}

/// Permanent delete (only after explicit confirmation in the UI).
pub fn delete_permanently(path: &Path) -> OpResult<()> {
    remove_any(path).map_err(io_err(path))
}

fn remove_any(path: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if meta.is_dir() { fs::remove_dir_all(path) } else { fs::remove_file(path) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("ff-ops-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn copy_never_overwrites_and_keeps_both_names() {
        let d = tmp("copy");
        fs::write(d.join("a.txt"), b"one").unwrap();
        fs::create_dir(d.join("out")).unwrap();
        fs::write(d.join("out/a.txt"), b"existing").unwrap();
        assert!(matches!(copy_item(&d.join("a.txt"), &d.join("out"), "a.txt"), Err(OpError::Exists(_))));
        assert_eq!(fs::read(d.join("out/a.txt")).unwrap(), b"existing");
        let free = unique_name(&d.join("out"), "a.txt");
        assert_eq!(free, "a 2.txt");
        copy_item(&d.join("a.txt"), &d.join("out"), &free).unwrap();
        assert_eq!(fs::read(d.join("out/a 2.txt")).unwrap(), b"one");
        // no partial leftovers
        assert!(fs::read_dir(d.join("out")).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().contains("ffpartial")));
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn copies_folders_recursively_and_links_as_links() {
        let d = tmp("tree");
        fs::create_dir_all(d.join("src/inner")).unwrap();
        fs::write(d.join("src/inner/f"), b"x").unwrap();
        symlink("/etc", d.join("src/link")).unwrap();
        fs::create_dir(d.join("dst")).unwrap();
        copy_item(&d.join("src"), &d.join("dst"), "src").unwrap();
        assert_eq!(fs::read(d.join("dst/src/inner/f")).unwrap(), b"x");
        assert!(fs::symlink_metadata(d.join("dst/src/link")).unwrap().file_type().is_symlink());
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn refuses_into_itself() {
        let d = tmp("self");
        fs::create_dir_all(d.join("a/b")).unwrap();
        assert!(matches!(move_item(&d.join("a"), &d.join("a/b"), "a"), Err(OpError::IntoItself(_))));
        assert!(matches!(copy_item(&d.join("a"), &d.join("a"), "a"), Err(OpError::IntoItself(_))));
        assert!(d.join("a/b").is_dir());
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn move_same_volume_and_conflict() {
        let d = tmp("move");
        fs::write(d.join("f"), b"1").unwrap();
        fs::create_dir(d.join("to")).unwrap();
        move_item(&d.join("f"), &d.join("to"), "f").unwrap();
        assert!(!d.join("f").exists() && d.join("to/f").exists());
        fs::write(d.join("f"), b"2").unwrap();
        assert!(matches!(move_item(&d.join("f"), &d.join("to"), "f"), Err(OpError::Exists(_))));
        assert_eq!(fs::read(d.join("to/f")).unwrap(), b"1");
        assert_eq!(fs::read(d.join("f")).unwrap(), b"2");
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn rename_rules() {
        let d = tmp("rename");
        fs::write(d.join("a.txt"), b"a").unwrap();
        fs::write(d.join("b.txt"), b"b").unwrap();
        assert!(matches!(rename_item(&d.join("a.txt"), "b.txt"), Err(OpError::Exists(_))));
        assert!(matches!(rename_item(&d.join("a.txt"), "x/y"), Err(OpError::InvalidName(_))));
        rename_item(&d.join("a.txt"), "A.txt").unwrap(); // case-only
        assert!(fs::read_dir(&d).unwrap().any(|e| e.unwrap().file_name() == "A.txt"));
        let f = new_folder(&d).unwrap();
        assert_eq!(name_of(&f), "untitled folder");
        assert_eq!(name_of(&new_folder(&d).unwrap()), "untitled folder 2");
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn copy_reports_size_and_cancel_keeps_the_source() {
        let d = tmp("prog");
        fs::write(d.join("a.txt"), vec![7u8; 4096]).unwrap();
        fs::create_dir(d.join("out")).unwrap();
        let calls = std::cell::Cell::new(0u32);
        let last = std::cell::Cell::new((0u64, 0u64));
        let copied = copy_item_reporting(&d.join("a.txt"), &d.join("out"), "a.txt", &|c, t, file| {
            calls.set(calls.get() + 1);
            last.set((c, t));
            assert!(!file.is_empty());
            assert!(t == 0 || c <= t);
            true
        })
        .unwrap();
        assert!(calls.get() >= 1);
        assert_eq!(last.get(), (4096, 4096));
        assert_eq!(fs::read(&copied).unwrap(), vec![7u8; 4096]);

        let err = copy_item_reporting(&d.join("a.txt"), &d.join("out"), "b.txt", &|_, _, _| false);
        assert!(matches!(err, Err(OpError::Cancelled)));
        assert!(d.join("a.txt").is_file());
        assert!(!d.join("out/b.txt").exists());
        assert!(fs::read_dir(d.join("out")).unwrap().all(|e| {
            !e.unwrap().file_name().to_string_lossy().contains("ffpartial")
        }));
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn copy_directory_progress_total_is_file_bytes() {
        let d = tmp("dtree");
        fs::create_dir_all(d.join("src/inner")).unwrap();
        fs::write(d.join("src/a"), vec![1u8; 10]).unwrap();
        fs::write(d.join("src/inner/b"), vec![2u8; 20]).unwrap();
        fs::create_dir(d.join("dst")).unwrap();
        let last = std::cell::Cell::new((0u64, 0u64));
        copy_item_reporting(&d.join("src"), &d.join("dst"), "src", &|c, t, _| {
            assert!(t == 0 || c <= t);
            last.set((c, t));
            true
        })
        .unwrap();
        assert_eq!(last.get(), (30, 30));
        assert_eq!(fs::read(d.join("dst/src/inner/b")).unwrap().len(), 20);
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn move_same_volume_reports_done() {
        let d = tmp("mprog");
        fs::write(d.join("f"), b"1").unwrap();
        fs::create_dir(d.join("to")).unwrap();
        let last = std::cell::Cell::new((0u64, 0u64));
        move_item_reporting(&d.join("f"), &d.join("to"), "f", &|c, t, _| {
            last.set((c, t));
            true
        })
        .unwrap();
        assert_eq!(last.get(), (1, 1));
        assert!(d.join("to/f").is_file());
        assert!(!d.join("f").exists());
        fs::remove_dir_all(d).unwrap();
    }
}
