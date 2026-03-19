#!/bin/bash
mkdir -p "${PWD}/shared"
docker build -t cs295-lab2 . && \
	docker run -it --entrypoint /bin/bash -v "${PWD}/shared:/home/student/shared:z" cs295-lab2
