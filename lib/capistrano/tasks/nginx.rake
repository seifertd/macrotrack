require "stringio"

# The nginx vhost is version-controlled at config/deploy/nginx/ so a rebuilt box
# (or a certbot rewrite) can be reconciled against a known-good copy.
#
# Installing it is *not* fully automatic: /etc/nginx is root-owned and sudo on
# das requires a password, which Capistrano cannot supply non-interactively.
# So the split is:
#
#   nginx:check    non-privileged, runs on every deploy, reports drift only
#   nginx:install  stages the file and installs it if passwordless sudo exists,
#                  otherwise prints the exact commands to run by hand
namespace :nginx do
  set :nginx_conf_name, -> { "macros.dseifert.net.conf" }
  set :nginx_conf_dir,  -> { "/etc/nginx/conf.d" }

  def local_nginx_conf
    File.expand_path("../../../../config/deploy/nginx/#{fetch(:nginx_conf_name)}", __FILE__)
  end

  desc "Upload the version-controlled nginx vhost to shared/config/nginx/"
  task :stage do
    name     = fetch(:nginx_conf_name)
    contents = File.read(local_nginx_conf)

    on roles(:web) do
      staged_dir = "#{shared_path}/config/nginx"
      execute :mkdir, "-p", staged_dir
      upload! StringIO.new(contents), "#{staged_dir}/#{name}"
      info "Staged #{name} at #{staged_dir}/#{name}"
    end
  end

  desc "Report drift between the repo's nginx vhost and the installed one"
  task check: :stage do
    name = fetch(:nginx_conf_name)

    on roles(:web) do
      installed = "#{fetch(:nginx_conf_dir)}/#{name}"
      staged    = "#{shared_path}/config/nginx/#{name}"

      unless test("[ -f #{installed} ]")
        warn "nginx: #{installed} does not exist on the host — run `cap production nginx:install`"
        next
      end

      diff = capture(:diff, "-u", installed, staged, raise_on_non_zero_exit: false)
      if diff.strip.empty?
        info "nginx: #{name} on the host matches the repo"
      else
        warn "nginx: #{name} DRIFTS from the repo (host <, repo >):"
        warn diff
        warn "nginx: reconcile with `cap production nginx:install`, or copy the host's version back into config/deploy/nginx/"
      end
    end
  end

  desc "Install the staged nginx vhost, validate, and reload (needs sudo)"
  task install: :stage do
    name = fetch(:nginx_conf_name)

    on roles(:web) do
      installed = "#{fetch(:nginx_conf_dir)}/#{name}"
      staged    = "#{shared_path}/config/nginx/#{name}"
      backup    = "#{shared_path}/config/nginx/#{name}.installed.bak"

      unless test(:sudo, "-n", "true")
        warn "nginx: passwordless sudo unavailable on #{host}. File is staged; run these yourself:"
        warn "  ssh -t #{host} 'sudo cp #{installed} #{backup} 2>/dev/null; sudo cp #{staged} #{installed} && sudo nginx -t && sudo systemctl reload nginx'"
        next
      end

      execute :sudo, "-n", "cp", installed, backup, raise_on_non_zero_exit: false
      execute :sudo, "-n", "cp", staged, installed

      # Roll back rather than leave nginx holding a config it refuses to load.
      if test(:sudo, "-n", "nginx", "-t")
        execute :sudo, "-n", "systemctl", "reload", "nginx"
        info "nginx: installed and reloaded #{name}"
      else
        execute :sudo, "-n", "cp", backup, installed
        error "nginx: `nginx -t` failed; restored the previous #{name} and did NOT reload"
      end
    end
  end
end

# Drift detection is cheap and unprivileged, so it runs with every deploy.
after "deploy:publishing", "nginx:check"
