server "das", user: "doug", roles: %w[app web db]

set :deploy_to, "/home/doug/webapps/macrotrack/production"

set :ssh_options, {
  forward_agent: true,
  auth_methods: %w[publickey password]
}
