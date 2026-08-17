# config valid only for current version of Capistrano
set :application, "macrotrack"
set :repo_url, "git@github.com:seifertd/macrotrack.git"
set :user, "doug"
set :group, "doug"
set :use_sudo, false
set :tmp_dir, "/tmp"
set :branch, ENV["BRANCH"] || "main"

set :deploy_via, :remote_cache
set :scm_verbose, true

# config/master.key and config/*.key are gitignored, so they live in
# shared/config/ on the host and are symlinked into each release.
append :linked_files, "config/database.yml", "config/master.key", "config/credentials.yml.enc"

# `storage` holds Active Storage blobs (the WP5 audio) and must survive a
# release swap, so it lives in shared/ rather than inside the release.
append :linked_dirs, "log", "tmp/pids", "tmp/cache", "tmp/sockets", "public/system", "storage"

set :keep_releases, 3

# tailwindcss-rails scans views/js to determine which CSS classes to emit,
# so changes to these files must trigger asset recompilation on deploy.
append :assets_dependencies, "app/views", "app/javascript", "app/components", "app/helpers"

# RVM settings
# Single source of truth: derive ruby@gemset from the version-controlled files so
# a Ruby/gemset bump can't leave the systemd unit pinned to a stale rvm wrapper.
# .ruby-version here carries a "ruby-" prefix; rvm wants it exactly once.
set :rvm_ruby_version, "ruby-#{File.read('.ruby-version').strip.sub(/\Aruby-/, '')}@#{File.read('.ruby-gemset').strip}"
set :rvm_type, :system
