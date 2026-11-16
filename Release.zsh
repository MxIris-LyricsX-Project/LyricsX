# How AppRelease (https://github.com/Mx-Iris/AppRelease) ships LyricsX. Pushing a v* tag runs it on
# GitHub Actions (.github/workflows/release.yml). Every setting is described in AppRelease's README;
# CLAUDE.md, "Release Workflow", has the steps of a release.
release_engine_version=1.2.0

release_project=LyricsX.xcodeproj
release_scheme=LyricsX
# The scheme also builds the LyricsXHelper login item, an app of its own.
release_application_target=LyricsX

# Resolve LyricsKit and MusicPlayer from their pinned tags, never from sibling checkouts
# (LyricsXPackage/Package.swift reads this).
export LYRICSX_USE_LOCAL_DEPENDENCY=0

# The project keeps its version numeric (MARKETING_VERSION in Config/Version.xcconfig, e.g. 1.9.1); a
# prerelease adds its suffix to the tag only (v1.9.1-beta.1). The build number is encoded from the
# whole tag, so builds sort across alpha, beta, rc and final (Documentations/BuildNumberScheme.md).
release_version_tag_match=base
release_build_number_source=semantic-version-encoding

# Release signs every target by hand with Developer ID and a provisioning profile of its own
# (Config/*/*-Release.xcconfig), so the export names the same profiles. On CI AppRelease installs them
# from APP_RELEASE_PROVISIONING_PROFILE_*_BASE64.
release_export_options_path=ExportOptions.plist
release_archive_arguments=(
    # A fresh CI runner has never been asked to trust the macros and plugins in the package graph.
    -skipMacroValidation -skipPackagePluginValidation
    OTHER_CODE_SIGN_FLAGS=--timestamp
)

release_product_name='LyricsX_{tag_version}+{build}.zip'
release_publishers=(github-release sparkle-appcast)
# The GitHub Release shows the English notes, a rule, then the Chinese ones; release_compose_notes
# writes them here from ReleaseNotes/.
release_notes_path='build/AppRelease/ReleaseNotes/{tag_version}.md'
# generate_appcast writes this release into a feed of its own; release_deploy_appcast copies the item
# into the two live feeds.
release_appcast_path=build/AppRelease/LyricsX/appcast-item.xml

# Only for a release made on this Mac; CI notarizes with an App Store Connect key.
release_notary_keychain_profile=notarytool-password

# Every release ships with notes in both languages, written beforehand (CLAUDE.md, "Release notes
# conventions"). Without them a release stops here, before anything is built.
release_preflight() {
    [[ $app_release_publishes == true ]] || return 0
    local tag_version=${app_release_tag#v} language notes_path
    for language in en zh; do
        notes_path=ReleaseNotes/${tag_version}_$language.md
        [[ -s $app_release_project_directory/$notes_path ]] ||
            app_release_fail "no release notes at $notes_path; write them before releasing"
    done
    # Left by an earlier run of the same version: compose the notes again from the files as they are
    # now, and give generate_appcast an empty feed.
    rm -f "$app_release_project_directory/build/AppRelease/ReleaseNotes/$tag_version.md" \
        "$app_release_project_directory/$release_appcast_path"
}

release_compose_notes() {
    local notes_path=$1 tag_version=${app_release_tag#v}
    mkdir -p "${notes_path:h}"
    {
        cat "$app_release_project_directory/ReleaseNotes/${tag_version}_en.md"
        printf '\n\n---\n\n'
        cat "$app_release_project_directory/ReleaseNotes/${tag_version}_zh.md"
    } > "$notes_path"
}

# The main app and its login item both carry the App Groups entitlement, which backs the preferences
# they share (launching with the player). A profile that does not authorize it makes taskgated reject
# the entitlement on other Macs, and the feature breaks silently, as it did in 1.8.6.
release_verify_export() {
    local application_path=$1 bundle_path profile_path decoded_profile_path
    decoded_profile_path=$(mktemp -t LyricsXProfile)
    for bundle_path in "$application_path" "$application_path/Contents/Library/LoginItems/LyricsXHelper.app"; do
        profile_path=$bundle_path/Contents/embedded.provisionprofile
        [[ -f $profile_path ]] ||
            app_release_fail "${bundle_path:t} has no embedded.provisionprofile, so its App Groups entitlement is not authorized"
        security cms -D -i "$profile_path" > "$decoded_profile_path" 2> /dev/null
        /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups' \
            "$decoded_profile_path" > /dev/null 2>&1 ||
            app_release_fail "the provisioning profile of ${bundle_path:t} does not authorize com.apple.security.application-groups"
        app_release_detail "${bundle_path:t}: the embedded profile authorizes App Groups"
    done
    rm -f "$decoded_profile_path"
}

# The dSYMs go up with the release, named like the app's zip, so a crash report from any release can
# be symbolicated.
release_after_product() {
    local products_directory=$1
    local symbols_archive_path=$app_release_run_directory/DebugSymbols/LyricsX.dSYMs.zip
    local product_path=$products_directory/LyricsX_${app_release_tag#v}+$app_release_build_number.dSYMs.zip
    [[ -f $symbols_archive_path ]] || app_release_fail "the archive has no dSYMs"
    cp "$symbols_archive_path" "$product_path"
    app_release_add_product "$product_path" --not-notarized
}

# Two live feeds take every release. 1.8.x and older read appcast.xml on this repository's master
# through its Pages site; 1.9.0 and later read the organization site's appcast.xml (SUFeedURL). Each
# gets this release's item spliced in front of the others and nothing else changed: generate_appcast
# would rewrite every item it read, and the two feeds differ in their oldest items. A private key that
# does not match the app's SUPublicEDKey only makes generate_appcast warn and leave the item unsigned;
# insert-appcast-item.py then stops before either feed changes.
release_deploy_appcast() {
    local generated_feed_path=$1
    local deployment_directory=$app_release_run_directory/AppcastDeployment
    rm -rf "$deployment_directory"
    mkdir -p "$deployment_directory"
    lyricsx_deploy_feed "$generated_feed_path" "$deployment_directory/LyricsX" \
        MxIris-LyricsX-Project/LyricsX master "${GH_TOKEN:-}"
    lyricsx_deploy_feed "$generated_feed_path" "$deployment_directory/OrganizationSite" \
        MxIris-LyricsX-Project/MxIris-LyricsX-Project.github.io '' "${PAGES_MIRROR_TOKEN:-}"
}

# lyricsx_deploy_feed <generated feed> <clone directory> <repository> <branch, or '' for the default> <token>
# Clones the repository, splices this release's item into its appcast.xml, commits and pushes. On CI it
# pushes with the token; on a Mac, with the user's own git credentials.
lyricsx_deploy_feed() {
    local generated_feed_path=$1 clone_directory=$2 repository=$3 branch=$4 token=$5
    local tag_version=${app_release_tag#v}
    local repository_url=https://github.com/$repository.git
    local -a branch_arguments=() identity_arguments=()
    if [[ ${GITHUB_ACTIONS:-} == true ]]; then
        [[ -n $token ]] || app_release_fail "no token to push to $repository from CI"
        repository_url=https://x-access-token:$token@github.com/$repository.git
        identity_arguments=(-c 'user.name=github-actions[bot]' -c 'user.email=github-actions[bot]@users.noreply.github.com')
    fi
    if [[ -n $branch ]]; then
        branch_arguments=(--branch "$branch")
    fi
    git clone --quiet --depth 1 "${branch_arguments[@]}" "$repository_url" "$clone_directory"
    python3 "$app_release_project_directory/Scripts/insert-appcast-item.py" \
        --feed "$clone_directory/appcast.xml" --generated-feed "$generated_feed_path" \
        --build "$app_release_build_number" --version "$tag_version" \
        --release-notes "$app_release_project_directory/ReleaseNotes/${tag_version}_en.md"
    if git -C "$clone_directory" diff --quiet -- appcast.xml; then
        app_release_detail "$repository already lists v$tag_version"
        return 0
    fi
    git "${identity_arguments[@]}" -C "$clone_directory" commit --quiet \
        -m "release: update appcast.xml for v$tag_version" -- appcast.xml
    git -C "$clone_directory" push --quiet origin HEAD
    app_release_detail "$repository: appcast.xml now lists v$tag_version"
}
