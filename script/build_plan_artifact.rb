# Renders the /plan page as a standalone fragment for publishing as an Artifact.
#
#   bin/rails runner script/build_plan_artifact.rb [OUT_PATH]
#
# Uses the same view and stylesheet as the in-app page, so the hosted and
# published copies can't drift apart. Emits <title> + <style> + content with no
# <html>/<head>/<body> wrapper, which is what the Artifact publisher expects.

out = ARGV.first || Rails.root.join("tmp", "plan-artifact.html").to_s

body, packages = PlanDocument.render
renderer = ApplicationController.renderer

styles = renderer.render(partial: "plan/styles")
content = renderer.render(
  template: "plan/show",
  layout: false,
  assigns: { body:, packages: },
  locals: { standalone: true }
)

File.write(out, <<~HTML)
  <title>MacroTrack Build Plan</title>
  #{styles}
  #{content}
HTML

puts "wrote #{out} (#{File.size(out)} bytes, #{packages.size} work packages)"
