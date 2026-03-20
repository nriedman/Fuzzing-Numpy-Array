#!/bin/bash
mkdir -p "${PWD}/shared"
docker build -t cs295-lab2 . && \
	docker run -it --entrypoint /bin/bash -v "${PWD}:/home/student:z" cs295-lab2
