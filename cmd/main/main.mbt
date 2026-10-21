///|
async fn main {
  let args = @env.args()
  let args = if args.is_empty() { [] } else { args[1:].to_owned() }
  // Async cancellation bypasses catch clauses. Let the watch renderer restore
  // its terminal first, then apply gh's watch interrupt exit status instead of
  // the runtime re-raising SIGINT. Embedding APIs retain normal cancellation.
  defer (if @async.is_being_cancelled() &&
    args.get(0) == Some("run") &&
    args.get(1) == Some("watch") {
    @sys.exit(1)
  })
  let output = @native.run_github(
    args,
    stdout_writer=bytes => @stdio.stdout.write(bytes),
    stderr_writer=bytes => @stdio.stderr.write(bytes),
  ) catch {
    _ => {
      @stdio.stderr.write("gh: command interrupted or runtime unavailable\n") catch {
        _ => ()
      }
      @sys.exit(if @async.is_being_cancelled() { 2 } else { 1 })
      return
    }
  }
  @stdio.stdout.write(output.stdout_bytes()) catch {
    _ => @sys.exit(1)
  }
  @stdio.stderr.write(output.stderr) catch {
    _ => @sys.exit(1)
  }
  @sys.exit(output.exit_code)
}
