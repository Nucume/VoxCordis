# Website

The VoxCordis website, served by GitHub Pages at https://nucume.github.io/VoxCordis/.

It is one page with everything inline (about 120 KB, plus the font and the
favicon), built by a small script with no packages:

    python3 website/build.py    # -> website/out/

- `src/home.html` is the welcome screen and the tour (the app rebuilt for the
  web, with Voxette as the example companion); `build.py` adds the other
  sections (privacy, download, setting up, the guide, questions) and the footer.
- `src/site.js` holds the theme and Colorways (kept in localStorage as
  `vc-theme` and `vc-way`), the download buttons and the apt/dnf commands.
- `static/` is copied as is: the Hanken Grotesk font (SIL OFL, see
  `static/fonts/OFL.txt`) is served from the site itself, so a visit sends
  nothing to Google.

Publishing happens in the public repository: its Website workflow
(`.github/workflows/pages.yml`) runs on changes to `website/` on main and puts
`out/` at the root of the `gh-pages` branch. It never touches `repo/` there,
which is the apt and dnf repository the release workflow keeps.
