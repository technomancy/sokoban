# Sokoban

User-space builds.

Accepts git pushes over HTTP. Launches a receiver process using the
user's Heroku API key to accept the push and forwards it there once
it's up. Stores an app->dyno mapping in Redis.

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
