class ApplicationMailer < ActionMailer::Base
  # A real address on the deployed domain rather than the generator's from@example.com.
  # Nothing receives replies here — the only mail this app sends is a password reset —
  # but the envelope sender is what SPF/DMARC are checked against, so a domain we do not
  # own is the difference between "delivered" and "silently binned".
  default from: "no-reply@macros.dseifert.net"
  layout "mailer"
end
