Hatjitsu
========

Create disposable online [Planning Poker](http://en.wikipedia.org/wiki/Planning_poker) rooms for quick and easy estimations.

Features
========

* Simple interface
* No login/signup required
* Votes are kept hidden until all have voted to prevent coercion
* 'Observer feature' - watch the planning session without having to vote
* Multiple planning card decks
* Adaptive design allows to work on desktop, tablet and mobile

Installation
============

    npm install ci
    node server.js

[http://localhost:5000](http://localhost:5000)

Testing
=======

    npm test

Runs unit tests for `lib/` and integration tests that start the server on a random port
and exercise the HTTP routes and Socket.IO events (create/join room, vote, reveal, reset, ...).

Installation (Docker)
=====================

Just checkout the repository and run:

    docker-compose up -d

TODOs
=====

* [x] Collapsible card view / jump to votes on vote
* [x] Update favicon, iOS splash page, Twitter avatar etc with new design
* [ ] Unicode symbol fallback (coffee/ace/king)
* [x] Improve CTA buttons
* [ ] Testing harness
