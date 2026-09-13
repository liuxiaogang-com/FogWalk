param([Parameter(Mandatory)][string]$SourcePath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Asset-format conversion only: preserve the supplied artwork, remove outside
# transparent padding, and export the opaque 1024 px image required by AppIcon.
$source = [System.Drawing.Bitmap]::new((Resolve-Path -LiteralPath $SourcePath).Path)
$output = $null
$graphics = $null
try {
    $left = $source.Width; $top = $source.Height; $right = -1; $bottom = -1
    for ($y = 0; $y -lt $source.Height; $y++) {
        for ($x = 0; $x -lt $source.Width; $x++) {
            if ($source.GetPixel($x, $y).A -gt 0) {
                $left = [Math]::Min($left, $x); $right = [Math]::Max($right, $x)
                $top = [Math]::Min($top, $y); $bottom = [Math]::Max($bottom, $y)
            }
        }
    }
    if ($right -lt $left) { throw 'The source icon is entirely transparent.' }
    $side = [Math]::Max($right - $left + 1, $bottom - $top + 1)
    $crop = [System.Drawing.RectangleF]::new(
        ($left + $right + 1 - $side) / 2, ($top + $bottom + 1 - $side) / 2, $side, $side)
    $output = [System.Drawing.Bitmap]::new(1024, 1024, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($output)
    $graphics.Clear([System.Drawing.Color]::FromArgb(4, 55, 70))
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.DrawImage($source, [System.Drawing.RectangleF]::new(0, 0, 1024, 1024), $crop, [System.Drawing.GraphicsUnit]::Pixel)
    $target = Join-Path $PSScriptRoot '../FogWalk/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
    $output.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output "Converted source bounds $crop to opaque 1024x1024 AppIcon.png"
    Get-FileHash -LiteralPath $SourcePath, $target -Algorithm SHA256
} finally {
    if ($graphics) { $graphics.Dispose() }
    if ($output) { $output.Dispose() }
    $source.Dispose()
}
