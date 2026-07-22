# Reto Browser icon layers

`RetoBrowserMinimal.icon` is the current Icon Composer document, and is the one built into the app (flattened into `Resources/Assets.xcassets/AppIcon.appiconset`). It contains a white background and a circular `10-gradient.png` layer made from the supplied mesh-gradient image. The globe line art and decorative layers have been removed.

The gradient layer is a 1024 by 1024 PNG with transparent corners and a crisp circular edge, so Icon Composer keeps the mesh texture inside a smaller circle while the white background remains visible around it. Liquid Glass effects are disabled; the depth comes from the supplied soft gradient and texture.

`RetoBrowser.icon` (globe + eyes + spark) and `RetoBrowserDoodle.icon` (globe + spark) are earlier, unused variants kept for reference.
