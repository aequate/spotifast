use librespot_core::cache::Cache;
use std::path::{Component, Path};

pub const AUDIO_BUDGET: u64 = 128 * 1024 * 1024;

pub fn open(audio_directory: Option<&Path>) -> Result<Cache, librespot_core::Error> {
    open_with_limit(audio_directory, AUDIO_BUDGET)
}

fn open_with_limit(directory: Option<&Path>, limit: u64) -> Result<Cache, librespot_core::Error> {
    // Only the native host supplies this app-container directory. Credentials
    // and volume deliberately have no disk location, as in desktop open_cache.
    if let Some(path) = directory
        && (!path.is_absolute()
            || path.parent().is_none()
            || path.components().any(|part| part == Component::ParentDir))
    {
        return Err(librespot_core::Error::invalid_argument(
            "Invalid audio cache directory",
        ));
    }
    Cache::new(None, None, directory, Some(limit)).map(Cache::with_memory_credentials)
}

#[cfg(test)]
mod tests {
    use super::*;
    use librespot_core::{FileId, authentication::Credentials};
    use std::{fs, io::Read, time::SystemTime};

    struct Directory(std::path::PathBuf);
    impl Directory {
        fn new() -> Self {
            let id = SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            Self(
                std::env::temp_dir()
                    .join(format!("spotifast-ios-cache-{}-{id}", std::process::id())),
            )
        }
    }
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn actual_librespot_cache_reopens_audio_without_writing_credentials() {
        let directory = Directory::new();
        let cache = open(Some(&directory.0)).unwrap();
        let id = FileId([1; 20]);
        let bytes = b"opaque-cache-test-bytes";
        cache.save_file(id, &mut &bytes[..]).unwrap();
        cache.save_credentials(&Credentials::with_access_token("temporary-test-grant"));
        assert!(cache.credentials().is_some());
        assert!(!directory.0.join("credentials.json").exists());
        drop(cache);
        let reopened = open(Some(&directory.0)).unwrap();
        let mut data = Vec::new();
        reopened.file(id).unwrap().read_to_end(&mut data).unwrap();
        assert_eq!(data, bytes);
        assert!(reopened.credentials().is_none());
    }

    #[test]
    fn actual_librespot_cache_prunes_to_the_budget() {
        let directory = Directory::new();
        let cache = open_with_limit(Some(&directory.0), 16).unwrap();
        let ids = [FileId([1; 20]), FileId([2; 20]), FileId([3; 20])];
        for id in ids {
            cache.save_file(id, &mut &[7u8; 10][..]).unwrap();
        }
        let retained: Vec<_> = ids.into_iter().filter_map(|id| cache.file(id)).collect();
        assert_eq!(retained.len(), 1);
        assert!(
            retained
                .iter()
                .map(|file| file.metadata().unwrap().len())
                .sum::<u64>()
                <= 16
        );
        drop(cache);
        // A smaller budget is also enforced when the cache is reopened.
        let reopened = open_with_limit(Some(&directory.0), 1).unwrap();
        assert!(ids.into_iter().all(|id| reopened.file(id).is_none()));
    }

    #[test]
    fn cache_refuses_relative_and_parent_directories() {
        for path in ["relative", "../outside"] {
            assert!(open(Some(Path::new(path))).is_err());
        }
        assert!(open(Some(&std::env::temp_dir().join("spotifast/../outside"))).is_err());
        assert!(open(None).is_ok());
    }
}
