REPO     := monkeytypegame/monkeytype
RAW      := https://raw.githubusercontent.com/$(REPO)/master
REPO_API := https://api.github.com/repos/$(REPO)
GH_TREE  := $(REPO_API)/git/trees/master?recursive=1
GH_LOG   := $(REPO_API)/commits?path=frontend/static/languages&per_page=1

HF_REPO  := much1na/words-monkeytype

all: train.csv

tmp:
	mkdir -p tmp

tmp/files.json: tmp
	wget -q "$(GH_TREE)" -O tmp/files.json

tmp/languages.txt: tmp/files.json
	jq -r '.tree[].path' tmp/files.json | grep 'frontend/static/languages/' > tmp/languages.txt

tmp/urls.txt: tmp/languages.txt
	cat tmp/languages.txt | xargs -I{} echo "$(RAW)/{}" > tmp/urls.txt

tmp/data: tmp/urls.txt
	mkdir -p tmp/data
	wget2 -nc -i tmp/urls.txt -P tmp/data
	touch tmp/data

train.csv: tmp/data
	duckdb -c "COPY (SELECT unnest(words) as word, name as wordlist FROM read_json('tmp/data/*.json') ORDER BY name, wordlist, word) TO 'train.csv'"

languages.json: tmp/data
	jq -s '[.[] | del(.words)]' tmp/data/*.json > languages.json

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
	jq -r '.[0].sha' tmp/languages-commit.json > tmp/upstream-sha

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

clean:
	rm -rf tmp

.PHONY: all clean inject-stats stats bot-commit upload-hf
