///|
async fn main {
  let args = @env.args()
  let args = if args.is_empty() { [] } else { args[1:].to_owned() }
  let output = @native.run(args) catch {
    _ => {
      @stdio.stderr.write("gh: command interrupted or runtime unavailable\n") catch {
        _ => ()
      }
      @sys.exit(1)
      return
    }
  }
  @stdio.stdout.write(output.stdout) catch {
    _ => @sys.exit(1)
  }
  @stdio.stderr.write(output.stderr) catch {
    _ => @sys.exit(1)
  }
  @sys.exit(output.exit_code)
}
