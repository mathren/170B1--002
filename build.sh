#!/bin/bash

# check if we want to build all the files of not
contains_all_flag() {
    for arg in "$@"; do
        if [ "$arg" == "--all" ]; then
            return 0  # all found
        fi
    done
    return 1  # all not found
}

# check if we want to bypass read prompts
contains_y_flag() {
    for arg in "$@"; do
        if [ "$arg" == "-y" ]; then
            return 0  # -y found
        fi
    done
    return 1  # -y not found
}


# Wrapper to call emacs with no customized configuration (-Q) and run build-site.el
if contains_all_flag "$@"; then
    emacs -Q --script build-site.el -- all
else
    emacs -Q --script build-site.el
fi

if [ $? -eq 0 ]; then
    echo "Successfully built site locally with emacs!"
    echo ""
    git status
    echo ""

    if contains_y_flag "$@"; then
	yn="Y";
    else
	read -p "Push everything to repo? [Y/n] " yn
    fi
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
	git remote -v
	if [ -z "$1" ]; then # if $1 is a null string
	    echo "one"
	    # make up a commit message
	    git add .
	    git commit -am "Update website"
	    git push
	else
	    echo "two"
	    git add .
	    git commit -am "$@"
	    git push
	fi
	pushed=true
    else
	pushed=false
    fi

    if [ "$pushed" == true ] ; then
	pulled=false
	if contains_y_flag "$@"; then
	    yn="Y";
	else
	    read -p "rsync to remote server?" yn
	fi
	if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
	    rsync -arz --exclude="*~" html-content/* lavinia:~/public_html/courses/170B1--02/
	    if [ $? -eq 0 ]; then
		pulled=true
	    fi
	fi
    else
	if contains_y_flag "$@"; then
	    yn="Y";
	else
	    read -p "Open website home locally?" yn
	fi
	if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
	    # open in browser and quit
	    pulled=false
	    xdg-open ./html-content/index.html
	    exit 1
	else
	    pulled=false
	    echo "Ok, not opening!"
	    exit 1
	fi
    fi

    echo ""
    echo "Summary:"
    echo ""

    if [ "$pushed" == false ] ; then
	echo "Done: local build, not pushed, check html file"
    else
	if [ "$pulled" == true ] ; then
	    echo "Done: local build pushed, and synced with remote! Website is online at https://www.as.arizona.edu/~mrenzo/courses/170B1--02/index.html"
	else
	    echo "Done: local build pushed, but not synced with remote! Latest version of website is *NOT* online"
	fi
    fi
else
    echo "Building failed. See error above"
fi

# option to pull from the repo -- useful if building remotely the html files
# read -p "Pull from the repo?" yn
# case $yn in
#     [Yy]* ) git pull;;
#     [Nn]* ) true;;
#     * ) echo "Please answer yes or no.";;
# esac
