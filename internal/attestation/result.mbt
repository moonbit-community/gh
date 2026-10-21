///|
fn distinguished_name(name : @pkix.Name) -> String raise VerificationError {
  let parts : Array[String] = []
  for index = name.rdns.length() - 1; index >= 0; index = index - 1 {
    let rdn : Array[String] = []
    for attribute in name.rdns[index] {
      let key = match attribute.oid.to_string() {
        "2.5.4.3" => "CN"
        "2.5.4.6" => "C"
        "2.5.4.7" => "L"
        "2.5.4.8" => "ST"
        "2.5.4.9" => "STREET"
        "2.5.4.10" => "O"
        "2.5.4.11" => "OU"
        "2.5.4.5" => "SERIALNUMBER"
        "2.5.4.17" => "POSTALCODE"
        other => other
      }
      let value = match attribute.value.value {
        PrintableString(value) | Utf8String(value) | Ia5String(value) => value
        _ =>
          raise Invalid("unsupported certificate distinguished name encoding")
      }
      let text = StringBuilder()
      for i, c in value {
        if c is (',' | '+' | '"' | '\\' | '<' | '>' | ';') ||
          (i == 0 && c is (' ' | '#')) ||
          (i == value.length() - 1 && c == ' ') {
          text.write_char('\\')
        }
        text.write_char(c)
      }
      rdn.push(key + "=" + text.to_string())
    }
    parts.push(rdn.join("+"))
  }
  parts.join(",")
}

///|
pub fn VerifiedRelease::verification_result(self : VerifiedRelease) -> Json {
  {
    "mediaType": "application/vnd.dev.sigstore.verificationresult+json;version=0.1",
    "signature": {
      "certificate": {
        "certificateIssuer": self.issuer,
        "subjectAlternativeName": "https://dotcom.releases.github.com",
      },
    },
    "verifiedTimestamps": [
      {
        "type": "TimestampAuthority",
        "uri": self.timestamp_uri,
        "timestamp": self.timestamp_text,
      },
    ],
    "verifiedIdentity": {
      "subjectAlternativeName": {
        "subjectAlternativeName": "",
        "regexp": "^https://dotcom\\.releases\\.github\\.com$",
      },
      "issuer": { "issuer": "", "regexp": ".*" },
    },
    "statement": self.statement,
  }
}
