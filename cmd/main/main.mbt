///|
async fn main {
  let args = @env.args()
  let args = if args.is_empty() { [] } else { args[1:].to_owned() }
  let output = @native.run_github(args) catch {
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
