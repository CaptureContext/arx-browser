# Arx design rules

Rules for how Arx's interface is built, in code and in Figma (`Arx-Browser`, Components pages). When code and Figma disagree with a rule here, the rule wins and the other one is the bug.

## Lists

A list is any stack of rows that a highlight moves through: the command bar's results, ⌘K's actions, the destination picker (Runway), Little Arx's and Page PiP's space pickers, hover previews' lists, the sidebar.

- **Rows touch.** The stack has no spacing between rows. The gap between two highlights is padding inside each row: a row whose highlight is `h` tall with a gap `g` to the next is `h + g` tall, and its highlight sits `g / 2` in from its top and bottom. The rows stay the same distance apart, but nothing between them belongs to no row, so a row's frame is everything that's that row's.
- **The list's inset is content padding.** The distance from the list's container to the first and last highlight is padding on the scrolled content, inside the scroll view, never around it. Scrolled to the top or the bottom, the first or last row keeps that inset.
- **Scrolling keeps a row whole.** When the keyboard moves the highlight to a row off screen, scroll the row in with its padding and the list's inset, so no highlight is ever cut by the list's edge.
- **Floating controls reserve room.** A control that floats over a list, such as the command bar's Actions ⌘K, adds its height, its inset from the edge and a gap to the content padding at that end, so the last row scrolls clear of it.
- **Corners are concentric.** A highlight inside a container is rounded to the container's radius less its inset from the container's edge.
