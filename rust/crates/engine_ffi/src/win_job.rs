//! Process tree management so canceling a download terminates the full
//! `yt-dlp.exe` bootloader, worker, JS runtime, and `ffmpeg.exe` child tree.

use std::io;
use tokio::process::Child;

/// Owns a process-tree termination handle for a spawned child process.
#[derive(Debug)]
pub struct ProcessTreeJob {
    pid: Option<u32>,
    #[cfg(windows)]
    job: Option<WinJobHandle>,
}

#[cfg(windows)]
#[derive(Debug)]
struct WinJobHandle(windows_sys::Win32::Foundation::HANDLE);

#[cfg(windows)]
// SAFETY: A Win32 Job Object HANDLE is kernel-managed and safe to transfer and share across threads.
unsafe impl Send for WinJobHandle {}
#[cfg(windows)]
// SAFETY: Win32 `TerminateJobObject` and `CloseHandle` are thread-safe kernel operations.
unsafe impl Sync for WinJobHandle {}

#[cfg(windows)]
impl Drop for WinJobHandle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: `self.0` was created by `CreateJobObjectW` and is closed once on drop.
            unsafe {
                windows_sys::Win32::Foundation::CloseHandle(self.0);
            }
        }
    }
}

impl ProcessTreeJob {
    /// Attaches `child` to an OS process-tree supervisor (Windows Job Object on Windows).
    pub fn attach(child: &Child) -> io::Result<Self> {
        let pid = child.id();

        #[cfg(windows)]
        {
            let job = create_kill_on_close_job()?;
            if let Some(raw_handle) = child.raw_handle() {
                let proc_handle = raw_handle as windows_sys::Win32::Foundation::HANDLE;
                // SAFETY: `job.0` and `proc_handle` are valid Win32 handles for the active child.
                let assigned = unsafe {
                    windows_sys::Win32::System::JobObjects::AssignProcessToJobObject(
                        job.0,
                        proc_handle,
                    )
                };
                if assigned == 0 {
                    return Err(io::Error::last_os_error());
                }
            }
            Ok(Self {
                pid,
                job: Some(job),
            })
        }

        #[cfg(not(windows))]
        {
            Ok(Self { pid })
        }
    }

    /// Terminates the process and all descendants spawned by it.
    pub fn terminate(&self) -> io::Result<()> {
        #[cfg(windows)]
        {
            let mut job_ok = false;
            if let Some(job) = &self.job {
                // SAFETY: `job.0` is a valid open Win32 Job Object handle.
                let ok =
                    unsafe { windows_sys::Win32::System::JobObjects::TerminateJobObject(job.0, 1) };
                job_ok = ok != 0;
            }
            if !job_ok {
                if let Some(pid) = self.pid {
                    kill_process_tree_fallback(pid)?;
                }
            }
            Ok(())
        }

        #[cfg(not(windows))]
        {
            let _ = self.pid;
            Ok(())
        }
    }
}

#[cfg(windows)]
fn create_kill_on_close_job() -> io::Result<WinJobHandle> {
    use std::ffi::c_void;
    use std::mem::{size_of, zeroed};
    use std::ptr::{addr_of, null};
    use windows_sys::Win32::System::JobObjects::{
        CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };

    // SAFETY: Null security attributes and unnamed job object per Win32 documentation.
    let raw = unsafe { CreateJobObjectW(null(), null()) };
    if raw.is_null() {
        return Err(io::Error::last_os_error());
    }
    let handle = WinJobHandle(raw);

    // SAFETY: Plain POD Win32 struct zero-initialized before setting `LimitFlags`.
    let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { zeroed() };
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

    // SAFETY: `handle.0` is valid and `info` matches `JobObjectExtendedLimitInformation` size.
    let updated = unsafe {
        SetInformationJobObject(
            handle.0,
            JobObjectExtendedLimitInformation,
            addr_of!(info).cast::<c_void>(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
    };
    if updated == 0 {
        return Err(io::Error::last_os_error());
    }

    Ok(handle)
}

#[cfg(windows)]
fn kill_process_tree_fallback(pid: u32) -> io::Result<()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    let status = std::process::Command::new("taskkill.exe")
        .args(["/F", "/T", "/PID", &pid.to_string()])
        .creation_flags(CREATE_NO_WINDOW)
        .output()?
        .status;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "taskkill failed for PID {pid} with status {status}"
        )))
    }
}
