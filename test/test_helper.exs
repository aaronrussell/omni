# Hide debug-level catalog-load lines from model sources in test output.
Logger.configure(level: :info)

ExUnit.start(exclude: [:live])
