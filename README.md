# Sokoban

User-space builds.

Accepts git pushes over HTTP. Launches a receiver process using the
user's Heroku API key to accept the push and forwards it there once
it's up. Stores an app->dyno mapping in Redis.

## Components

Currently Sokoban consists of three parts. Each is a sub-command of
`bin/sokoban`.

### Proxy

Accepts incoming HTTP requests and forwards them to a receiver.
Manages the life cycle of receivers and maps app names to receiver
dynos. This is the only part of the app which contains secrets; the
rest runs as the user performing the push. Thus it's also responsible
for setting up pre-signed URLs for S3.

### Receiver

Accepts HTTP requests from git for a specific app. Receivers are
designed to be disposable and be used for a single push. They run as
an app under the account of the user doing the push. It's possible to
push directly to a receiver instead of going through the proxy if you
provide it with everything the proxy normally provides:

* `app_id`
* `buildpack_url`
* `repo_url`
* `repo_put_url`
* `slug_url`
* `slug_put_url`

## Hooks

The receiver is simply an HTTP server that accepts uploads; it's the
git client itself that's responsible for signaling when the push is
complete. This is done via hooks. Sokoban uses the **pre-receive**
hook to trigger a compilation of the codebase being pushed. Once it's
compiled, it uploads the slug and performs a `POST` to Heroku's
release API to finish the deploy. If that succeeds, the
**post-receive** hook archives the repository itself to S3 for the
next push.

## Steps

* [X] Pushing straight to receiver updates local copy of repo
* [X] Direct receiver runs slug compilation
* [ ] Direct receiver can post a release
* [ ] Pushing to proxy with hard-coded receiver URL
* [ ] Pushing to an actual dyno
* [ ] Pushing to multiple receiver dynos tracked in redis
* [ ] Handle all failure modes

## Current Issues

* Launching receiver often times out
* Pushes display "bad line length character: 10" error but succeed.

## Failure modes

* Auth
* API outage
* Redis outage
* Git deactivated (for app or system-wide)
* User disappears
* Dyno launch timeout
* Dyno disappears
* Dyno becomes unresponsive
* Fetch failure (repo or buildpack)
* Compile failure (user error)
* Stow failure (repo or slug)
* Release failure
