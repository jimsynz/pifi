// **The accent of the interface does not follow the artwork any more.**
//
// The palette of the product holds six colours and each one means one thing, so an
// accent that changed with the cover meant one thing on one track and another thing
// on the next. That is the same decision that the screens of the device make: see
// `PiFi.Screen.Style` and `PiFi.Peripheral.PiTft.Screen`.
//
// The hook stays and it sets nothing, so the server can keep sending the event and no
// page has to know. `PiFi.Artwork.Accent` still reads the picture, because the
// artwork page of a later version may want it.
export const accent = () => {}
