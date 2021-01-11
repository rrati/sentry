SHELL:=/bin/bash
IMAGE_PREFIX := quay.io/app-sre
IMAGE_TAG := $(shell git rev-parse --short=7 HEAD)

SENTRY_INITIAL_EMAIL ?= tester@fake.com
SENTRY_INITIAL_PASSWORD ?= test

ifneq ($(GITHUB_APP_ID),)
	APP_ID := -e "GITHUB_APP_ID=$(GITHUB_APP_ID)"
endif

ifneq ($(GITHUB_API_SECRET),)
	APP_SECRET := -e "GITHUB_API_SECRET=$(GITHUB_API_SECRET)"
endif

ifneq (,$(wildcard $(CURDIR)/.docker))
	DOCKER_CONF := $(CURDIR)/.docker
else
	DOCKER_CONF := $(HOME)/.docker
endif

SNUBA_OPTS = --link sentry-kafka:kafka --link sentry-redis:redis --link sentry-clickhouse:clickhouse -e "SNUBA_SETTINGS=docker" -e "CLICKHOUSE_HOST=clickhouse" -e "CLICKHOUSE_PORT=9000" -e "DEFAULT_BROKERS=kafka:9092" -e "REDIS_HOST=redis" -e "REDIS_PORT=6379"
SENTRY_OPTS = --link sentry-redis:redis --link sentry-symbolicator:symbolicator --link sentry-postgres:postgres --link sentry-kafka:kafka --link sentry-snuba-api:snuba-api -e "SENTRY_CONF=/etc/sentry" -e "SNUBA=http://snuba-api:1218" -e "SENTRY_SECRET_KEY='$(key)'" $(APP_ID) $(APP_SECRET) -e "SENTRY_SINGLE_ORGANIZATION=True"

.PHONY: build
build: sentryimage symbolicatorimage snubaimage

sentryimage:
	@docker build --pull -t $(IMAGE_PREFIX)/sentry:latest sentry
	@docker tag $(IMAGE_PREFIX)/sentry:latest $(IMAGE_PREFIX)/sentry:$(IMAGE_TAG)

symbolicatorimage:
	@docker build --pull -t $(IMAGE_PREFIX)/symbolicator:latest symbolicator
	@docker tag $(IMAGE_PREFIX)/symbolicator:latest $(IMAGE_PREFIX)/symbolicator:$(IMAGE_TAG)

snubaimage:
	@docker build --pull -t $(IMAGE_PREFIX)/snuba:latest snuba
	@docker tag $(IMAGE_PREFIX)/snuba:latest $(IMAGE_PREFIX)/snuba:$(IMAGE_TAG)

.PHONY: push
push:
	@docker --config=$(DOCKER_CONF) push $(IMAGE_PREFIX)/sentry:latest
	@docker --config=$(DOCKER_CONF) push $(IMAGE_PREFIX)/sentry:$(IMAGE_TAG)

.PHONY: prerequp
prerequp:
	docker run -d --name sentry-redis redis
	docker run -d --name sentry-postgres --env POSTGRES_PASSWORD=secret --env POSTGRES_USER=sentry postgres:9.6
	docker run -d --name sentry-clickhouse --mount type=bind,source=$(PWD)/test/config/clickhouse.xml,target=/etc/clickhouse-server/config.d/sentry.xml yandex/clickhouse-server:20.3.9.70

.PHONY: localup
localup: prerequp snubaup sentryup

.PHONY: sentryup
sentryup:
	@$(eval key := $(shell docker run --rm -it $(IMAGE_PREFIX)/sentry:latest sentry config generate-secret-key))

	# Symbolicator
	docker run --link sentry-redis:redis --link sentry-postgres:postgres --link sentry-kafka:kafka -e "SNUBA=http://snuba-api:1218" -e "SENTRY_SECRET_KEY='$(key)'" -d --name sentry-symbolicator ${IMAGE_PREFIX}/symbolicator:latest run -c /etc/symbolicator/config.yml

	# DB init
	docker run --rm -it $(SENTRY_OPTS) $(IMAGE_PREFIX)/sentry:latest upgrade --noinput
	docker run --rm -it $(SENTRY_OPTS) $(IMAGE_PREFIX)/sentry:latest sentry createuser --email ${SENTRY_INITIAL_EMAIL} --password ${SENTRY_INITIAL_PASSWORD} --superuser --no-input

	# Sentry
	docker run -d --name sentry-cron $(SENTRY_OPTS) $(IMAGE_PREFIX)/sentry:latest run cron
	docker run -d --name sentry-web-01 $(SENTRY_OPTS) --publish 9000:9000 $(IMAGE_PREFIX)/sentry:latest run web
	docker run -d --name sentry-worker-01 $(SENTRY_OPTS) $(IMAGE_PREFIX)/sentry:latest run worker
	docker run -d --name sentry-ingest-consumer $(SENTRY_OPTS) $(IMAGE_PREFIX)/sentry:latest run ingest-consumer --all-consumer-types
	docker run -d --name sentry-post-process-forwarder $(SENTRY_OPTS) $(IMAGE_PREFIX)/sentry:latest run post-process-forwarder --commit-batch-size 1
	docker run -d --name sentry-subscription-consumer-events $(SENTRY_OPTS) $(IMAGE_PREFIX)/sentry:latest run query-subscription-consumer --commit-batch-size 1 --topic events-subscription-results
	docker run -d --name sentry-subscription-consumer-transactions $(SENTRY_OPTS) $(IMAGE_PREFIX)/sentry:latest run query-subscription-consumer --commit-batch-size 1 --topic transactions-subscription-results
	@echo "You can now access sentry on http://localhost:9000 with user $(SENTRY_INITIAL_EMAIL) and password $(SENTRY_INITIAL_PASSWORD)"

.PHONY: kafkaup
kafkaup:
	docker run -d --name sentry-zookeeper -e "ZOOKEEPER_CLIENT_PORT=2181" -e "ZOOKEEPER_LOG4J_ROOT_LOGLEVEL=WARN" -e "ZOOKEEPER_TOOLS_LOG4J_LOGLEVEL=WARN" zookeeper:3.6.2
	docker run -d --name sentry-kafka --link sentry-zookeeper:zookeeper --publish 9092:9092 -e "KAFKA_ZOOKEEPER_CONNECT=zookeeper:2181" -e "KAFKA_LISTENERS=PLAINTEXT://:9092" -e "KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://:9092" -e "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1" -e "KAFKA_OFFSETS_TOPIC_NUM_PARTITIONS=1" -e "KAFKA_LOG_RETENTION_HOURS=24" -e "CONFLUENT_SUPPORT_METRICS_ENABLE=false" -e "KAFKA_LOG4J_LOGGERS=kafka.cluster=WARN,kafka.controller=WARN,kafka.coordinator=WARN,kafka.log=WARN,kafka.server=WARN,kafka.zookeeper=WARN,state.change.logger=WARN" -e "KAFKA_LOG4J_ROOT_LOGLEVEL=WARN" -e "KAFKA_TOOLS_LOG4J_LOGLEVEL=WARN" wurstmeister/kafka:2.13-2.7.0
	@$(eval TOPICS := ingest-attachments ingest-transactions ingest-events)
	for topic in $(TOPICS); do \
	  docker run --rm -it --link sentry-kafka:kafka wurstmeister/kafka:2.13-2.7.0 kafka-topics.sh --create --topic $$topic --bootstrap-server kafka:9092; \
	done

.PHONY: prereqdown
prereqdown:
	docker stop sentry-redis sentry-postgres sentry-clickhouse
	docker rm sentry-redis sentry-postgres sentry-clickhouse

.PHONY: localdown
localdown: snubadown sentrydown

.PHONY: sentrydown
sentrydown:
	docker stop sentry-cron sentry-web-01 sentry-worker-01 sentry-symbolicator sentry-ingest-consumer sentry-post-process-forwarder sentry-subscription-consumer-events sentry-subscription-consumer-transactions
	docker rm sentry-cron sentry-web-01 sentry-worker-01 sentry-symbolicator sentry-ingest-consumer sentry-post-process-forwarder sentry-subscription-consumer-events sentry-subscription-consumer-transactions

.PHONY: kafkadown
kafkadown:
	docker stop sentry-zookeeper sentry-kafka
	docker rm sentry-zookeeper sentry-kafka

.PHONY: snubaup
snubaup: prerequp kafkaup
	docker run --rm -it $(SNUBA_OPTS) ${IMAGE_PREFIX}/snuba:latest snuba bootstrap --no-migrate --force
	docker run --rm -it $(SNUBA_OPTS) ${IMAGE_PREFIX}/snuba:latest snuba migrations migrate --force
	docker run -d --name sentry-snuba-api $(SNUBA_OPTS) ${IMAGE_PREFIX}/snuba:latest snuba api
	docker run -d --name sentry-snuba-consumer $(SNUBA_OPTS) ${IMAGE_PREFIX}/snuba:latest snuba consumer --storage events --auto-offset-reset=latest --max-batch-time-ms 750
	docker run -d --name sentry-snuba-outcomes-consumer $(SNUBA_OPTS) ${IMAGE_PREFIX}/snuba:latest snuba consumer --storage outcomes_raw --auto-offset-reset=earliest --max-batch-time-ms 750
	docker run -d --name sentry-snuba-sessions-consumer $(SNUBA_OPTS) ${IMAGE_PREFIX}/snuba:latest snuba consumer --storage sessions_raw --auto-offset-reset=latest --max-batch-time-ms 750
	docker run -d --name sentry-snuba-transactions-consumer $(SNUBA_OPTS) ${IMAGE_PREFIX}/snuba:latest snuba consumer --storage transactions --consumer-group transactions_group --auto-offset-reset=latest --max-batch-time-ms 750 --commit-log-topic=snuba-commit-log
	docker run -d --name sentry-snuba-replacer $(SNUBA_OPTS) ${IMAGE_PREFIX}/snuba:latest snuba replacer --storage events --auto-offset-reset=latest --max-batch-size 3
	docker run -d --name sentry-snuba-subscription-consumer-events $(SNUBA_OPTS) ${IMAGE_PREFIX}/snuba:latest snuba subscriptions --auto-offset-reset=latest --consumer-group=snuba-events-subscriptions-consumers --topic=events --result-topic=events-subscription-results --dataset=events --commit-log-topic=snuba-commit-log --commit-log-group=snuba-consumers --delay-seconds=60 --schedule-ttl=60
	docker run -d --name sentry-snuba-subscription-consumer-transactions $(SNUBA_OPTS) ${IMAGE_PREFIX}/snuba:latest snuba subscriptions --auto-offset-reset=latest --consumer-group=snuba-transactions-subscriptions-consumers --topic=events --result-topic=transactions-subscription-results --dataset=transactions --commit-log-topic=snuba-commit-log --commit-log-group=transactions_group --delay-seconds=60 --schedule-ttl=60

.PHONY: snubadown
snubadown: kafkadown prereqdown
	docker stop sentry-snuba-api sentry-snuba-consumer sentry-snuba-outcomes-consumer sentry-snuba-sessions-consumer sentry-snuba-transactions-consumer sentry-snuba-replacer sentry-snuba-subscription-consumer-events sentry-snuba-subscription-consumer-transactions
	docker rm sentry-snuba-api sentry-snuba-consumer sentry-snuba-outcomes-consumer sentry-snuba-sessions-consumer sentry-snuba-transactions-consumer sentry-snuba-replacer sentry-snuba-subscription-consumer-events sentry-snuba-subscription-consumer-transactions
