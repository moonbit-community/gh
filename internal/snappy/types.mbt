///|
pub suberror SnappyError {
  CorruptInput(String)
  UnexpectedEOF
}

///|
const TAG_LITERAL : Int32 = 0

///|
const TAG_COPY1 : Int32 = 1

///|
const TAG_COPY2 : Int32 = 2
