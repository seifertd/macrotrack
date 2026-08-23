# MacroTrack — what an agent should know before touching this

A two-person household calorie tracker. Rails 8, Postgres, Hotwire, deployed to a
single self-hosted box. The design docs in `doc/` are the source of truth for *why*
things are the way they are — `macro-tracker-design.md` (with `-rev2`), and
`IMPLEMENTATION-PLAN.md` for what shipped when. Read the relevant § before arguing
with a decision; most of the surprising ones are argued for in a comment already.

**No secrets are recorded in this file, and none should be added to it.** Where each
one lives is noted; the values stay on the host and in `credentials.yml.enc`.

## Shape of the thing

- **Two users**, one household, no signup route by design (§4). Users come from
  `db/seeds.rb`, which takes passwords from `DOUG_PASSWORD` / `PARTNER_PASSWORD`
  in the environment so real ones never land in git.
- **Ruby 3.4.9**, gemset `macrotrack` (`.ruby-version` / `.ruby-gemset` are the single
  source of truth — `config/deploy.rb` derives the rvm wrapper path from them, which is
  what keeps the systemd unit from pinning a stale Ruby after a version bump).
- **AI**: `claude-opus-5`, 8192-token budget per chat turn. Roughly $0.037 per logged
  meal. Anthropic console spend for this account is entirely this app.
- **Voice**: whisper.cpp, self-hosted on the box, `small.en`. Not an API — there is no
  STT vendor and no per-minute cost. See `app/services/stt/whisper.rb` for why `small.en`
  and not `base.en`, and why there is deliberately no initial prompt.

## Production

| | |
|---|---|
| Host | `das` (ssh as `doug`, passwordless key auth) |
| URL | https://macros.dseifert.net |
| Deploy root | `/home/doug/webapps/macrotrack/production` |
| App server | Puma, 3 threads, bound to **:4001**, behind nginx |
| Jobs | Solid Queue **inside Puma** (`SOLID_QUEUE_IN_PUMA=1`) — one process, not two |
| Service | systemd **user** unit `macrotrack.service` (`systemctl --user`, not system-wide) |
| Database | Postgres; `macrotrack_production` plus `_cache` / `_queue` / `_cable` |
| Backups | nightly `script/backup_production_db.sh`, 30 days, into `/home/doug/webapps/backups/macrotrack` |
| Repo | `github.com/seifertd/macrotrack`, **private**, deploys from `main` |

It is a **2-core, 3GB box**, and that constrains real decisions. Puma's 3 threads, the
job workers and Postgres all share those two cores, and a whisper transcription takes
both of them for 8–12 seconds at normal priority, inline in a request thread. That trade
is deliberate (`voice_entries_controller.rb`), but it means "just add a worker" is not
free here.

### sudo needs a password

**SSH to `das` is passwordless; `sudo` is not.** Nothing automated can assume it. This is
why `nginx:check` (unprivileged, runs every deploy, reports drift) is split from
`nginx:install` (privileged, prints the exact commands when it can't run them).

Hand privileged steps to the user rather than trying to be clever — in Claude Code they
can run one inline with `! <command>`.

### Secrets, and where they are

- `config/master.key` — gitignored, untracked, lives in `shared/config/` on the host and
  is symlinked into each release. `credentials.yml.enc` is the only half that is committed.
- Database password — only in `shared/config/database.yml` (mode 600) on the host. The
  backup script parses it from there rather than keeping a second copy in `.pgpass`.
- Both are in `:linked_files`, so a release swap never touches them.

## Deploying

```sh
bundle exec cap production deploy          # from main; BRANCH=... to override
```

Capistrano + rvm, `remote_cache` from GitHub — **the branch must be pushed before you
deploy, or the box will build the previous commit.** On every deploy, in order:
assets → migrations (`db:prepare`, not `db:migrate`) → `nginx:check` →
`deploy:install_systemd_unit` → `systemctl --user restart`.

Two things worth knowing:

- **`db:prepare`, not `db:migrate`** (`:migration_command`). The Solid Cache/Queue/Cable
  databases are defined by `db/*_schema.rb` rather than migrations, and only `db:prepare`
  loads a schema into an empty one.
- **The systemd unit is regenerated from the repo on every deploy** from
  `config/deploy/templates/systemd_service.erb`. Never edit it on the server — a deploy
  will overwrite it. A Ruby/gemset bump that leaves the unit pinned to a stale rvm wrapper
  is what caused a 502 once; deriving the wrapper from `.ruby-version` is the fix, so keep
  it derived.

### Running anything on the box

There is **no `bundle` on `PATH` over ssh**. Use the rvm wrapper:

```sh
ssh das
cd /home/doug/webapps/macrotrack/production/current
/usr/local/rvm/wrappers/ruby-3.4.9@macrotrack/bundle exec rails <task>   # RAILS_ENV=production
```

### nginx

The vhost is version-controlled at `config/deploy/nginx/macros.dseifert.net.conf` so a
rebuilt box or a certbot rewrite can be reconciled against a known-good copy. TLS is
Let's Encrypt, managed by certbot — **don't hand-edit the `# managed by Certbot` lines.**
`client_max_body_size` is 25M on purpose: voice clips can be long.

## Verifying work here

`bin/rails test` (~280 tests, ~2s), `bin/rubocop`, `bin/brakeman -q`. All three should be
clean before a deploy; brakeman's baseline is **0 warnings / 3 ignored**, each ignore
carrying a reasoned note in `config/brakeman.ignore`.

Two traps that have already bitten:

- **Editing a query that brakeman ignores changes its fingerprint**, which resurfaces the
  warning as new. Re-point the existing entry and keep its note; don't suppress a fresh one.
- **A green suite is not a measurement.** Query counts and N+1s in this codebase have been
  established by counting `sql.active_record` / `instantiation.active_record` notifications
  inside a rolled-back transaction, and view refactors by diffing rendered HTML before and
  after. `CODE_REVIEW.md` records what was measured and how. Prefer that to inference — and
  check a new performance test actually fails against the old code, because an assertion
  measured on an already-loaded association passes vacuously.
