# Culife filters update

This builds on the live Group Cat Progress update.

1. Unzip this update.
2. Upload `catcul.html` and `sw.js` to the root of your GitHub Pages repository, replacing the existing files.
3. Upload the entire `jeeliz-filters` folder to the same repository root, keeping every subfolder and file in its original place. Do not upload the ZIP itself.
4. Wait for GitHub Pages to publish. Open Culife, then select **3D face filters** for the four Jeeliz effects, or **Lens Studio** for the 2D face effects and colour looks. Allow camera access when prompted.

The Jeeliz 3D effects require camera access, WebGL, and the included folder; they support photos in this update, not video. They may not work on every device. The 2D face effects use the existing MediaPipe browser loader and model files; they need an internet connection when those resources aren't cached. Depending on browser support, the 2D colour-look fallback uses a lower resolution and background blur may be unavailable.

Photo previews are not posted automatically: use the review controls to save or share. The 3D library and demos are from Jeeliz and their required license notices are in `jeeliz-filters`.
