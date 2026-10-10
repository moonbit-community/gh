///|
// Keep lock contention cancellable without occupying an upstream filesystem
// worker in a blocking OS lock call. Reuse the same advisory lock primitive
// for readers and writers; the enclosing operation owns its timeout.
async fn acquire_lock(file : @fs.File, kind : @fs.Lock) -> Unit {
  while !file.try_lock(kind) {
    @async.sleep(10)
  }
}
