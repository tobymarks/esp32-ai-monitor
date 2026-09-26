//! Import boundary for `.aimplugin` archives. The first format contains only
//! `plugin.json`; no archive member is extracted or executed.

use crate::plugin::{parse_manifest, Manifest, MAX_PACKAGE_MANIFEST_BYTES};
use sha2::{Digest, Sha256};
use std::io::{Cursor, Read};
use zip::ZipArchive;

pub const MAX_PACKAGE_BYTES: usize = 256 * 1024;

pub struct Package {
    pub manifest: Manifest,
    pub sha256: String,
}

pub fn parse_package(bytes: &[u8]) -> Result<Package, String> {
    if bytes.is_empty() || bytes.len() > MAX_PACKAGE_BYTES {
        return Err("plugin package size exceeds limit".into());
    }
    let mut archive = ZipArchive::new(Cursor::new(bytes)).map_err(|_| "invalid plugin archive")?;
    if archive.len() != 1 {
        return Err("package must contain only plugin.json".into());
    }
    let file = archive.by_index(0).map_err(|_| "invalid archive entry")?;
    if file.name() != "plugin.json"
        || file.is_dir()
        || file.size() > MAX_PACKAGE_MANIFEST_BYTES as u64
    {
        return Err("package must contain only plugin.json".into());
    }
    let mut manifest_bytes = Vec::with_capacity(file.size() as usize);
    file.take((MAX_PACKAGE_MANIFEST_BYTES + 1) as u64)
        .read_to_end(&mut manifest_bytes)
        .map_err(|_| "cannot read plugin manifest")?;
    let manifest = parse_manifest(&manifest_bytes)?;
    let sha256 = format!("{:x}", Sha256::digest(bytes));
    Ok(Package { manifest, sha256 })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::write::SimpleFileOptions;

    fn archive(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (name, content) in entries {
            writer
                .start_file(*name, SimpleFileOptions::default())
                .unwrap();
            writer.write_all(content).unwrap();
        }
        writer.finish().unwrap().into_inner()
    }

    #[test]
    fn accepts_fixture_and_rejects_extra_or_traversal_entry() {
        let manifest = include_bytes!("../../../../tests/fixtures/display-plugin/plugin.json");
        let good = archive(&[("plugin.json", manifest)]);
        assert_eq!(
            parse_package(&good).unwrap().manifest.id,
            "org.aimonitor.fixture"
        );
        assert!(parse_package(&archive(&[("../plugin.json", manifest)])).is_err());
        assert!(parse_package(&archive(&[
            ("plugin.json", manifest),
            ("run.sh", b"echo hi")
        ]))
        .is_err());
    }
}
