# The half of the JavaScript that can be checked without a browser — see test/javascript.
# Node's own runner: no dependency to install, nothing to build, and no package.json, so
# this stays a Rails app that happens to have some JS rather than a JS project. Kept out
# of `bin/rails test` on purpose; that command means the Ruby suite and should keep
# meaning it. bin/ci and .github/workflows/ci.yml run both.
namespace :test do
  desc "Run the browser-free JavaScript tests with node --test"
  task :js do
    # A directory argument is read as a module to run, not a tree to search — the glob is
    # what makes node discover them.
    abort "test:js needs node on PATH" unless system("node --version", out: File::NULL)
    abort "JavaScript tests failed" unless system("node", "--test", "test/javascript/**/*.mjs")
  end
end
