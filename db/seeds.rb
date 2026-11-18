# Users are seeded here rather than registered — there is no signup route by design (§4).
# Adding a third person later means adding a line here, not changing any queries.
#
# Email addresses and passwords come from the environment so real ones never land in
# git (the repo is public):
#   DOUG_EMAIL=... DOUG_PASSWORD=... PARTNER_EMAIL=... PARTNER_PASSWORD=... bin/rails db:seed
#
# There is deliberately no fallback address. Users are found by email, so a default that
# differed from the real one would quietly create a third account instead of updating yours.

TIMEZONE = "America/Los_Angeles".freeze

household = Household.find_or_create_by!(name: "Seifert")

MEMBERS = [
  { name: "Doug", email_env: "DOUG_EMAIL",
    password_env: "DOUG_PASSWORD", daily_calorie_target: 2000 },
  { name: ENV.fetch("PARTNER_NAME", "Partner"), email_env: "PARTNER_EMAIL",
    password_env: "PARTNER_PASSWORD", daily_calorie_target: 1600 }
].freeze

MEMBERS.each do |attributes|
  email_address = ENV[attributes[:email_env]]
  password = ENV[attributes[:password_env]]

  missing = { attributes[:email_env] => email_address, attributes[:password_env] => password }
    .select { |_, value| value.blank? }.keys
  if missing.any?
    warn "Skipping #{attributes[:name]}: set #{missing.join(' and ')} to seed this user."
    next
  end

  user = User.find_or_initialize_by(email_address: email_address)
  user.update!(
    household: household,
    name: attributes[:name],
    timezone: TIMEZONE,
    daily_calorie_target: attributes[:daily_calorie_target],
    password: password
  )

  puts "Seeded #{user.name} <#{user.email_address}> (#{user.timezone}) in #{household.name}"
end
