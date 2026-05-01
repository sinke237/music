.PHONY: format install-deps

format:
	isort generate.py wan
	yapf -i -r *.py generate.py wan

install-deps:
	pip install --upgrade pip setuptools wheel
	pip install -r requirements.txt --no-build-isolation
