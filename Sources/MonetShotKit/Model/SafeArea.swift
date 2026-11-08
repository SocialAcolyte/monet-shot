import CoreGraphics

/// Where words may go on a canvas: clear of the edges (and, in a tall frame,
/// of what phones lay over a video). A stand-in until the vertical work
/// lands with its own: the whole canvas inset by 6%.
public func safeArea(canvasWidth: Double, canvasHeight: Double) -> CGRect {
    CGRect(x: canvasWidth * 0.06, y: canvasHeight * 0.06, width: canvasWidth * 0.88, height: canvasHeight * 0.88)
}
