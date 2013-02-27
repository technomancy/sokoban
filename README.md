# Sokoban

User-space git builds.

A work in progress. Currently depends upon a manual installation of
the [slug compiler](https://github.com/heroku/slug-compiler).

Sokoban consists of three parts. Each is a sub-command of `bin/sokoban`.

## Proxy

Accepts incoming HTTP requests and forwards them to a receiver.
Manages the life cycle of receivers and maps app names to receiver
dynos. This is the only part of the app which contains secrets; the
rest runs as the user performing the push. Thus it's also responsible
for setting up pre-signed URLs for S3.

## Receiver

Accepts HTTP requests from git for a specific app. Receivers are
designed to be disposable and be used for a single push. They run as
an app under the account of the user doing the push.

The `bin/solo_receiver` script can emit a command with signed URLs
to launch a receiver for you if you want to run it without the proxy;
just provide it with an S3 bucket, AWS secret key, app name, and
buildpack URL. During normal usage the first two would be provided by
the proxy and the second two by the user initiating the push.

The receiver fetches the repository and receives new commits, but it
can't tell when the git push itself is complete; that's up to the git
client. So in order to trigger compilation when the push is complete,
the receiver installs hooks into the repository which the client
triggers.

## Hooks

Sokoban uses the **post-receive** hook to trigger a compilation of the
codebase being pushed. Once it's compiled, it uploads the slug and
performs a `POST` to Heroku's release API to finish the deploy. If
that succeeds, it archives the repository itself to S3 for the next
push.

## Milestones

* ☑ Pushing straight to receiver updates local copy of repo
* ☑ Direct receiver runs slug compilation
* ☐ Direct receiver can post a release
* ☐ Pushing to proxy with hard-coded receiver URL
* ☐ Pushing to an actual dyno
* ☐ Pushing to multiple receiver dynos tracked in redis
* ☐ Handle all failure modes

## Current Issues

* Launching receiver often times out
* Proxy pushes display "bad line length character: 10" error but succeed.

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
