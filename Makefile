REPO     := monkeytypegame/monkeytype
# A build is reproducible when UPSTREAM_REF is a commit SHA.  `master` is a
# convenient default for local updates, but is intentionally not used by CI.
UPSTREAM_REF ?= master
RAW      := https://raw.githubusercontent.com/$(REPO)/$(UPSTREAM_REF)
REPO_API := https://api.github.com/repos/$(REPO)
GH_TREE  := $(REPO_API)/git/trees/$(UPSTREAM_REF)?recursive=1
GH_LOG   := $(REPO_API)/commits/$(UPSTREAM_REF)

HF_REPO  := much1na/words-monkeytype

all: train.csv

tmp:
	mkdir -p tmp

tmp/files.json: tmp
	wget -q "$(GH_TREE)" -O tmp/files.json

tmp/languages.txt: tmp/files.json
	jq -r '.tree[] | select(.type == "blob") | .path' tmp/files.json | grep '^frontend/static/languages/.*\.json$$' | LC_ALL=C sort > tmp/languages.txt

tmp/urls.txt: tmp/languages.txt
	cat tmp/languages.txt | xargs -I{} echo "$(RAW)/{}" > tmp/urls.txt

tmp/data: tmp/urls.txt
	rm -rf tmp/data
	mkdir -p tmp/data
	while IFS= read -r url; do \
		file=$${url##*/}; \
		curl --fail --silent --show-error --location --retry 3 \
			--output "tmp/data/$$file" "$$url"; \
	done < tmp/urls.txt
	touch tmp/data

train.csv: tmp/data
	LC_ALL=C duckdb -c "PRAGMA threads=1; COPY (SELECT unnest(words) AS word, name AS wordlist FROM read_json('tmp/data/*.json') ORDER BY name, wordlist, word) TO 'train.csv.tmp' (HEADER, DELIMITER ',');"
	mv train.csv.tmp train.csv

languages.json: tmp/data
	LC_ALL=C jq -s '[.[] | del(.words)]' $$(LC_ALL=C find tmp/data -maxdepth 1 -type f -name '*.json' -print | LC_ALL=C sort) > languages.json

stats: tmp/data
	printf '## stats\n\n' > stats.md
	printf '### english\n' >> stats.md
	duckdb -markdown -c "SELECT name, len(words) as word_count FROM read_json('tmp/data/*.json') WHERE name LIKE 'english%' OR name LIKE 'wordle%' ORDER BY word_count DESC, name" >> stats.md
	printf '\n### code\n' >> stats.md
	duckdb -markdown -c "SELECT name, len(words) as word_count FROM read_json('tmp/data/*.json') WHERE name LIKE 'code_%' ORDER BY name" >> stats.md
	printf '\n### other\n' >> stats.md
	duckdb -markdown -c "SELECT name, len(words) as word_count FROM read_json('tmp/data/*.json') WHERE name NOT LIKE 'code_%' AND name NOT LIKE 'english%' AND name NOT LIKE 'wordle%' ORDER BY word_count DESC, name" >> stats.md
	printf '\n---\n' >> stats.md
	deno fmt stats.md
	sed -n '1,/<!-- stats:start -->/p' README.md > tmp/readme.tmp
	cat stats.md >> tmp/readme.tmp
	sed -n '/<!-- stats:end -->/,$$p' README.md >> tmp/readme.tmp
	mv tmp/readme.tmp README.md
	rm stats.md

inject-stats: stats

tmp/languages-commit.json: tmp
	curl -sf "$(GH_LOG)" > tmp/languages-commit.json

tmp/upstream-sha: tmp/languages-commit.json
	jq -r '.sha' tmp/languages-commit.json > tmp/upstream-sha

tmp/upstream-sha-short: tmp/upstream-sha
	cut -c1-7 tmp/upstream-sha > tmp/upstream-sha-short

tmp/upstream-commit.json: tmp/upstream-sha
	curl -sf "$(REPO_API)/commits/$$(cat tmp/upstream-sha)" > tmp/upstream-commit.json

tmp/upstream-msg: tmp/upstream-commit.json
	jq -r '.commit.message | split("\n")[0]' tmp/upstream-commit.json > tmp/upstream-msg

tmp/commit-msg: tmp/upstream-msg tmp/upstream-sha-short
	printf '%s\n\nupstream: $(REPO)@%s\n' "$$(cat tmp/upstream-msg)" "$$(cat tmp/upstream-sha-short)" > tmp/commit-msg

bot-commit: tmp/commit-msg
	git config user.name "github-actions[bot]"
	git config user.email "github-actions[bot]@users.noreply.github.com"
	git add README.md
	git diff --cached --quiet || git commit -F tmp/commit-msg

upload-hf: train.csv
	hf upload $(HF_REPO) train.csv train.csv --repo-type dataset
	hf upload $(HF_REPO) README.md README.md --repo-type dataset

clean:
	rm -rf tmp

.PHONY: all clean inject-stats stats bot-commit upload-hf
