// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "ZSeanYves/gh"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/moonbit-community/gh"

license = "Apache-2.0"

keywords = [ "moonhub", "cli", "api" ]

preferred_target = "native"

description = "A MoonBit port of gh adapted for MoonHub."

import {
  "moonbitlang/async@0.21.3",
  "moonbitlang/x@0.5.5",
  "moonbitstack/moonjson@0.4.0",
  "ZSeanYves/MoonbitHTTP@0.6.0",
}
