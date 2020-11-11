#!/bin/sh

# setup git-remote-hg plugin used to fetch from hg repositories, see:
# https://github.com/mnauw/git-remote-hg/
setup_git_plugin() {
    if ! [ -d "git-remote-hg" ] ; then
        mkdir -p "git-remote-hg" || return 1
        curl -f -L -o "${PWD}/git-remote-hg/git-remote-hg" "https://raw.githubusercontent.com/mnauw/git-remote-hg/v1.0.0/git-remote-hg" || return 1
        chmod +x "${PWD}/git-remote-hg/git-remote-hg" || return 1
    fi
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
    git config user.name ojdk-qa || return 1
    git config user.email ojdk-qa@github.com || return 1
    git config remote-hg.track-branches false || return 1
    archive_name="hg-${mirror}.tar.xz"
    archive_url_base="https://github.com/ojdk-qa/autoupdater/releases/download/hg-files-latest"
    archive_url="${archive_url_base}/${archive_name}"
    if ! curl -s -I "${archive_url}" | head -n 1 | grep -q '404 Not Found' ; then
       if ! curl -s -I "${archive_url_base}/tmp.${archive_name}" | head -n 1 | grep -q '404 Not Found' ; then
           # tmp file indicating archive update, should not happen
           return 1
       fi
       # fetch notes generated and required by the plugin
       git fetch origin "refs/notes/hg:refs/notes/hg" || return 1
       # unpack plugin's hg data from previous run
       curl -f -L -o "${archive_name}" "${archive_url}" || return 1
       tar -xJf "${archive_name}" -C .git || return 1
       rm -f "${archive_name}" || return 1
    fi
)

# fetch upstream changes into mirror repo
mirror_fetch_upstream() (
    subrepo="$1"
    shift
    repoSuffix=""
    if [ -n "${subrepo}" ] && ! [ "x${subrepo}" = "xroot" ] ; then
       repoSuffix="/${subrepo}"
    fi
    for project_repo in "${@}" ; do
        if [ "x${subrepo}" = "xnashorn" ] \
        && printf '%s' "${project_repo}" | grep -q "jdk7" ; then
            # jdk7 does not have nashorn
            continue
        fi
        git fetch "hg::https://hg.openjdk.java.net/${project_repo}${repoSuffix}" "master:${project_repo}" || return 1
    done
)

# push changes into mirror repo
mirror_push() (
    subrepo="$1"
    shift
    # replace each arg's value by value:value
    for project_repo in "${@}" ; do
        shift
        if [ "x${subrepo}" = "xnashorn" ] \
        && printf '%s' "${project_repo}" | grep -q "jdk7" ; then
            set -- "${@}"
        else
            set -- "${@}" "${project_repo}:${project_repo}"
        fi
    done
    if [ -n "${GH_CHANGES_ENV:-}" ] && [ -n "${GITHUB_ENV:-}" ] ; then
        tmpfile="$( mktemp )" || return 1
        onExit() {
            rm -f "${tmpfile}"
        }
        trap onExit EXIT
        if ! git push origin --tags "${@}" "refs/notes/hg:refs/notes/hg" 2> "$tmpfile" ; then
            cat "${tmpfile}"
            return 1
        fi
        cat "${tmpfile}"
        if ! cat "${tmpfile}" | grep -q '^Everything up-to-date$' ; then
            echo "${GH_CHANGES_ENV}=1" >> $GITHUB_ENV
        fi
        return 0
    fi
    git push origin --tags "${@}" "refs/notes/hg:refs/notes/hg" || return 1
)

# init all forest mirror repos
init_forest_mirrors() (
    forest_subrepos="corba hotspot jaxp jaxws jdk langtools nashorn root"
    for subrepo in ${forest_subrepos} ; do
        pushd "jdkforest-${subrepo}" || return 1
        mirror_init "jdkforest-${subrepo}" || return 1
        popd || return 1
    done
)

# update all forest mirror repos
update_forest_mirrors() (
    check_project_repos "${@}" || return 1
    forest_subrepos="corba hotspot jaxp jaxws jdk langtools nashorn root"
    for subrepo in ${forest_subrepos} ; do
        pushd "jdkforest-${subrepo}" > /dev/null || return 1
        mirror_fetch_upstream "${subrepo}" "${@}" || return 1
        popd > /dev/null || return 1
    done
    # todo: tag for automatic release here
    for subrepo in ${forest_subrepos} ; do
        pushd "jdkforest-${subrepo}" > /dev/null || return 1
        mirror_push "${subrepo}" "${@}" || 1
        popd > /dev/null || return 1
    done
)

# pack hg data for all forest mirror repos
pack_hg_forest_mirrors() (
    forest_subrepos="corba hotspot jaxp jaxws jdk langtools nashorn root"
    for subrepo in ${forest_subrepos} ; do
        # pack hg data (used by plugin)
        tar -cJf "hg-jdkforest-${subrepo}.tar.xz" -C "jdkforest-${subrepo}/.git" --exclude "hg/hg" hg || return 1
    done
)

# init hg-jdk mirror repo
init_jdk_mirror() (
    pushd "hg-jdk" > /dev/null || return 1
        mirror_init "hg-jdk" || return 1
    popd > /dev/null || return 1
)

# update hg-jdk mirror repo
update_jdk_mirror() (
    check_project_repos "${@}" || return 1
    pushd "hg-jdk" > /dev/null || return 1
        mirror_fetch_upstream "" "${@}" || return 1
        # todo: tag for automatic release here
        mirror_push "" "${@}" || return 1
    popd > /dev/null || return 1
)

# pack hg data for hg-jdk mirror repo
pack_hg_jdk_mirror() (
    # pack hg data (used by plugin)
    tar -cJf "hg-hg-jdk.tar.xz" -C "hg-jdk/.git" --exclude "hg/hg" hg || return 1
)

# update git-jdk mirror repo
update_git_jdk_mirror() (
    pushd "git-jdk"
        git config user.name ojdk-qa || return 1
        git config user.email ojdk-qa@github.com || return 1
        for project_repo in "${@}" ; do
            git fetch "https://github.com/openjdk/${project_repo}" "master:${project_repo}" || return 1
        done
        # todo: tag for automatic release here
        # replace each arg's value by value:value
        for project_repo in "${@}" ; do
            shift
            set -- "${@}" "${project_repo}:${project_repo}"
        done
        git push origin --tags "${@}" || return 1
    popd
)
