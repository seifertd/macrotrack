# Users are seeded here rather than registered — there is no signup route by design (§4).
# Adding a third person later means adding a line here, not changing any queries.
#
# Passwords come from the environment so real ones never land in git:
#   DOUG_PASSWORD=... PARTNER_PASSWORD=... bin/rails db:seed

TIMEZONE = "America/Los_Angeles".freeze

household = Household.find_or_create_by!(name: "Seifert")

MEMBERS = [
  { name: "Doug", email_address: "doug@dseifert.net",
    password_env: "DOUG_PASSWORD", daily_calorie_target: 2000 },
  { name: ENV.fetch("PARTNER_NAME", "Partner"),
    email_address: ENV.fetch("PARTNER_EMAIL", "partner@example.com"),
    password_env: "PARTNER_PASSWORD", daily_calorie_target: 1600 }
].freeze

MEMBERS.each do |attributes|
  password = ENV[attributes[:password_env]]

  if password.blank?
    warn "Skipping #{attributes[:name]}: set #{attributes[:password_env]} to seed this user."
    next
  end

  user = User.find_or_initialize_by(email_address: attributes[:email_address])
  user.update!(
    household: household,
    name: attributes[:name],
    timezone: TIMEZONE,
    daily_calorie_target: attributes[:daily_calorie_target],
    password: password
  )

  puts "Seeded #{user.name} <#{user.email_address}> (#{user.timezone}) in #{household.name}"
end
