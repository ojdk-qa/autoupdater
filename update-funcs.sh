#!/bin/sh

# setup git-remote-hg plugin used to fetch from hg repositories, see:
# https://github.com/mnauw/git-remote-hg/
setup_git_plugin() {
    mkdir -p "git-remote-hg"
    curl -f -L -o "${PWD}/git-remote-hg/git-remote-hg" "https://raw.githubusercontent.com/mnauw/git-remote-hg/v1.0.0/git-remote-hg"
    chmod +x "${PWD}/git-remote-hg/git-remote-hg"
    PATH="${PWD}/git-remote-hg:${PATH}"
}

# make sure all project repo names are valid
check_project_repos() (
    for project_repo in "${@}" ; do
        if ! printf "${project_repo}" | grep -E -q "[A-Za-z0-9_-]+/[A-Za-z0-9_-]+" ; then
            printf 'Invalid project repo %s\n' "${project_repo}" 1>&2
            return 1
        fi
    done
    return 0
)

# do initialization of cloned mirror repo
mirror_init() (
    mirror="$1"
    git config user.name ojdk-qa
    git config user.email ojdk-qa@github.com
    git config remote-hg.track-branches false
    archive_name="hg-${mirror}.tar.xz"
    archive_url="https://github.com/ojdk-qa/autoupdater/releases/download/hg-files-latest/${archive_name}"
    if ! curl -s -I "${archive_url}" | head -n 1 | grep -q '404 Not Found' ; then
       # fetch notes generated and required by the plugin
       git fetch origin "refs/notes/hg:refs/notes/hg"
       # unpack plugin's hg data from previous run
       curl -f -L -o "${archive_name}" "${archive_url}"
       tar -xJf "${archive_name}" -C .git
       rm -f "${archive_name}"
    fi
)

# fetch upstream changes into mirror repo
mirror_fetch_upstream() (
    subrepo="$1"
    shift
    repoSuffix=""
    if [ -n "${subrepo}" ] && ! [ "x${subrepo}" = "xtop" ] ; then
       repoSuffix="/${subrepo}"
    fi
    for project_repo in "${@}" ; do
        if [ "x${subrepo}" = "xnashorn" ] \
        && printf '%s' "${project_repo}" | grep -q "jdk7" ; then
            # jdk7 does not have nashorn
            continue
        fi
        git fetch "hg::https://hg.openjdk.java.net/${project_repo}${repoSuffix}" "master:${project_repo}"
    done
)

# push changes into mirror repo
mirror_push() (
    branchRefs=""
    # replace each arg's value by value:value
    for project_repo in "${@}" ; do
        shift
        set -- "${@}" "${project_repo}:${project_repo}"
    done
    git push origin --tags "${@}" "refs/notes/hg:refs/notes/hg"
)

# update all forest mirror repos
update_forest_mirrors() (
    check_project_repos "${@}" || return 1
    #forest_subrepos="corba hotspot jaxp jaxws jdk langtools nashorn top"
    forest_subrepos="jdk top"
    for subrepo in ${forest_subrepos} ; do
        pushd "jdkforest-${subrepo}"
        mirror_init "jdkforest-${subrepo}"
        mirror_fetch_upstream "${subrepo}" "${@}"
        popd
    done
    # todo: tag for automatic release here
    for subrepo in ${forest_subrepos} ; do
        pushd "jdkforest-${subrepo}"
        mirror_push "${@}"
        popd
        # pack hg data (used by plugin)
        tar -cJf "hg-jdkforest-${subrepo}.tar.xz" -C "jdkforest-${subrepo}/.git" --exclude "hg/hg" hg
    done
)

# update jdk mirror repo
update_jdk_mirror() (
    check_project_repos "${@}" || return 1
    pushd "jdk"
        mirror_init "jdk"
        mirror_fetch_upstream "" "${@}"
        # todo: tag for automatic release here
        mirror_push "${@}"
    popd
    # pack hg data (used by plugin)
    tar -cJf "hg-jdk.tar.xz" -C "jdk/.git" --exclude "hg/hg" hg
)
