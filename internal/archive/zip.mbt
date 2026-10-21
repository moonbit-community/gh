///|
/// Keep upstream entry storage alive instead of copying every inflated file.
/// These concrete types stay inside the archive adapter.
pub struct Entry {
  path : String
  directory : Bool
  executable : Bool
  priv source : @zip.Entry
}

///|
pub fn Entry::data(self : Entry) -> BytesView {
  self.source.data()
}

///|
pub fn Entry::path(self : Entry) -> String {
  self.path
}

///|
pub fn Entry::directory(self : Entry) -> Bool {
  self.directory
}

///|
pub fn Entry::executable(self : Entry) -> Bool {
  self.executable
}

///|
fn safe_name(name : String) -> (String, Bool) raise {
  guard !name.is_empty() &&
    !name.has_prefix("/") &&
    !name.contains_char('\\') &&
    @utf8.encode(name).length() <= 4096 &&
    name.iter().all(ch => ch.to_int() >= 32 && ch.to_int() != 127) else {
    fail("unsafe ZIP entry path")
  }
  let directory = name.has_suffix("/")
  let path = if directory { name[:name.length() - 1].to_owned() } else { name }
  for component in path.split("/") {
    guard !component.is_empty() &&
      component != "." &&
      component != ".." &&
      !component.contains(":") &&
      !component.has_suffix(".") &&
      !component.has_suffix(" ") &&
      @utf8.encode(component.to_owned()).length() <= 255 else {
      fail("unsafe ZIP path component")
    }
    let stem = component.split(".").next().unwrap_or("").to_owned().to_lower()
    if ["con", "prn", "aux", "nul"].contains(stem) ||
      (
        stem.length() == 4 &&
        (stem.has_prefix("com") || stem.has_prefix("lpt")) &&
        stem[3] is ('1'..<='9')
      ) {
      fail("reserved ZIP path component")
    }
  }
  (path, directory)
}

///|
/// Decode before touching the destination. flate validates ZIP framing and
/// sizes; its documented reader does not verify payload CRCs, so this adapter
/// verifies them explicitly and rejects filesystem aliases and special files.
pub fn decode_zip(
  bytes : BytesView,
  max_package_bytes~ : Int32 = 67108864,
  max_entry_bytes~ : Int32 = 134217728,
  max_total_bytes~ : Int32 = 268435456,
  max_entries~ : Int32 = 10000,
  cancelled~ : () -> Bool = () => false,
) -> Array[Entry] raise {
  guard max_package_bytes > 0 &&
    max_entry_bytes > 0 &&
    max_total_bytes > 0 &&
    max_entries > 0 else {
    fail("invalid ZIP limits")
  }
  let limits = @zip.ReadLimits::default()
    .with_package_limit(max_package_bytes)
    .with_preserved_source_limit(max_package_bytes)
    .with_entry_limit(max_entry_bytes)
    .with_total_limit(max_total_bytes)
    .with_entries_limit(max_entries)
  let archive = @zip.read(bytes, limits~, cancelled~)
  let entries : Array[Entry] = []
  let explicit : Map[String, Unit] = Map([])
  let paths : Map[String, Bool] = Map([])
  for source in archive.entries() {
    let (path, directory) = safe_name(source.name())
    // Lowercase aliases are rejected on every platform so an archive accepted
    // on Linux cannot overwrite another entry on a case-insensitive Mac.
    let canonical = path.to_lower()
    guard !explicit.contains(canonical) else {
      fail("duplicate ZIP entry path")
    }
    explicit[canonical] = ()
    if paths.get(canonical) is Some(existing) {
      guard existing && directory else {
        fail("ZIP file and directory conflict")
      }
    }
    paths[canonical] = directory
    let components = canonical.split("/").collect()
    let mut ancestor = ""
    for component in components[:components.length() - 1] {
      ancestor = if ancestor.is_empty() {
        component.to_owned()
      } else {
        ancestor + "/" + component.to_owned()
      }
      if paths.get(ancestor) == Some(false) {
        fail("ZIP entry traverses a file")
      }
      paths[ancestor] = true
    }
    guard source.raw_central_record() is Some(record) && record.length() >= 46 else {
      fail("ZIP central metadata missing")
    }
    let unix_mode = record[40].to_int() | (record[41].to_int() << 8)
    let kind = unix_mode & 0xf000
    guard kind == 0 ||
      (kind == 0x8000 && !directory) ||
      (kind == 0x4000 && directory) else {
      fail("ZIP symbolic link or special file is forbidden")
    }
    guard !directory || source.data().is_empty() else {
      fail("ZIP directory contains a payload")
    }
    guard @checksum.crc32_cancellable(source.data(), cancelled~) ==
      Some(source.crc32()) else {
      fail("ZIP CRC mismatch or cancellation")
    }
    entries.push({
      path,
      directory,
      executable: (unix_mode & 0o111) != 0,
      source,
    })
  }
  entries
}
