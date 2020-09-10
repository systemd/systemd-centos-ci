#!/usr/bin/bash

# This script generates a simple index HTML page to make possible
# investigation easier.
# Note: this is a single-purpose script which heavily depends on the directory
#       structure created by the systemd CentOS CI Jenkins job, as well as
#       its environment (i.e. env variables)

set -e
set -o pipefail

if [[ $# -ne 2 ]]; then
    echo >&2 "Usage: $0 artifacts_dir index_file"
    exit 1
fi

# Custom path to the 'tree' binary in CentOS CI
export PATH="/home/systemd/bin:$PATH"
ARTIFACTS_DIR="$1"
INDEX_FILE="$2"
CSS_FILE="$INDEX_FILE.css"

if [[ ! -d "$ARTIFACTS_DIR" ]]; then
    echo >&2 "'$ARTIFACTS_DIR' is not a directory"
    exit 1
fi

PR="${ghprbPullId:-N/A}"
PR_URL="${ghprbPullLink:-#}"

# Generate a nice HTML directory listing using the tree utility
tree --charset=utf-8 -C -T "systemd CentOS CI (PR#<a href='$PR_URL'>$PR</a>)" -H "$ARTIFACTS_DIR" "$ARTIFACTS_DIR" -o "$INDEX_FILE"

# Add some useful info below the main title
ADDITIONAL_INFO_FILE="$(mktemp)"
cat > "$ADDITIONAL_INFO_FILE" << EOF
<div>
<strong>Build URL:</strong> <a href='$BUILD_URL'>$BUILD_URL</a><br/>
<strong>Console log:</strong> <a href='$BUILD_URL/console'>$BUILD_URL/console</a><br/>
<strong>PR title:</strong> $ghprbPullTitle</br>
</div>
EOF
# 1) Add a newline after the </h1> tag, so we can use sed's patter matching
sed -i "s#</h1>#</h1>\n#" "$INDEX_FILE"
# 2) Append contents of the $ADDITIONAL_INFO_FILE after the </h1> tag
sed -i "/<\/h1>/ r $ADDITIONAL_INFO_FILE" "$INDEX_FILE"
# Delete the temporary file
rm -f "$ADDITIONAL_INFO_FILE"

# Use a relatively ugly sed to append a red cross after each "_FAIL" log file
sed -i -r 's/(_FAIL.log)(<\/a>)/\1 \&#x274C;\2/g' "$INDEX_FILE"

# Completely unnecessary workaround for CentOS CI Jenkins' CSP, which disallows
# inline CSS (but I want my colored links)
# Part 1: extract the inline CSS
grep --text -Pzo '(?s)(?<=<style type="text/css">)(.*)(?=</style>)' "$INDEX_FILE" | sed -e '/<!--/d' -e '/-->/d' > "$CSS_FILE"
# Part 2: link it back to the original index file
sed -i "/<head>/a<link rel=\"stylesheet\" href=\"$CSS_FILE\" type=\"text/css\">" "$INDEX_FILE"

LANDING_URL="${BUILD_URL}artifact/${PWD##$WORKSPACE}/index.html"

# As we can't expect to have 'cowsay' installed, let's make our own oversimplified
# version of it for absolutely no apparent reason. The picture below is, of course,
# borrowed from the cowsay package.
echo -n ' '; for ((i = 0; i < ${#LANDING_URL} + 2; i++)); do echo -n '_'; done
echo -ne "\n< $LANDING_URL >\n"
echo -n ' '; for ((i = 0; i < ${#LANDING_URL} + 2; i++)); do echo -n '-'; done
echo '
                       \                    ^    /^
                        \                  / \  // \
                         \   |\___/|      /   \//  .\
                          \  /O  O  \__  /    //  | \ \           *----*
                            /     /  \/_/    //   |  \  \          \   |
                            @___@`    \/_   //    |   \   \         \/\ \
                           0/0/|       \/_ //     |    \    \         \  \
                       0/0/0/0/|        \///      |     \     \       |  |
                    0/0/0/0/0/_|_ /   (  //       |      \     _\     |  /
                 0/0/0/0/0/0/`/,_ _ _/  ) ; -.    |    _ _\.-~       /   /
                             ,-}        _      *-.|.-~-.           .~    ~
            \     \__/        `/\      /                 ~-. _ .-~      /
             \____(oo)           *.   }            {                   /
             (    (--)          .----~-.\        \-`                 .~
             //__\\  \__ Ack!   ///.----..<        \             _ -~
            //    \\               ///-._ _ _ _ _ _ _{^ - - - - ~
'
