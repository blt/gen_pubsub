# gen_pubsub - an Erlang communication pattern behaviour

[![Build Status](https://travis-ci.org/blt/gen_pubsub.png)](https://travis-ci.org/blt/gen_pubsub)

The world doesn't want for message queues. Out of process something like
[RabbitMQ](http://www.rabbitmq.com/) or [Kafka](http://kafka.apache.org/) will
work, in-process [TinyMQ](https://github.com/evanmiller/tinymq) will act as a
one-stop-shop. I've found in larger projects I tend to have a few processes
which, among other duties, act as message channels, forwarding published
messages on to subscribed processes. This behaviour exists to formalize that
role and remove the tedium related to tracking subscriber processes.

At the moment, only subscribe/unsubscribe/publish actions are implemented--in
synchronous and asynchronous formed--and there exists no selective filtration of
published messages: broadcasts are pass/fail.

Please see the `test/gen_pubsub_SUITE` for an example implementation and
`src/gen_pubsub.erl` for in-line edocs.

- - -

This is a sketch of an idea and is not a production quality implementation,
possibly. I had the idea while on vacation, knocked it around a bit, started a
new job, knocked it around some more and here we are.
