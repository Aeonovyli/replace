This mod is for the free game Luanti, now specifically for the VoxeLibre fork.

Commands;

* pos1 = set the first corner of the area to be edited
* pos2 = set the second corner of the area to be edited
* fill_type = choose the selection shape: "fill_type rectangle" (default) or "fill_type sphere". Sphere is fitted inside the pos1/pos2 box, so a non-cubic box gives an ellipsoid. Works with replace, fill, delete, copy, and save
* setnode = set the node for replacing to either the node held or the node specified
* replace = by default no values, replace area selected with setnode; accepts wildcards such as mcl_core:* and "setnode" as a node name
* fill = completely replace everything in the area with setnode or the node specified; accepts wildcards and "setnode"
* delete = replace everything in area with air; accepts wildcards such as mcl_core:* and "setnode"
* water = a filter keyword usable with delete, replace, and fill. It means any liquid, so "delete water" removes liquids and "replace water <node>" or "fill water <node>" fills liquids with that node
* copy = save the non-air blocks, their metadata and timers, and any entities in the area to the internal clipboard; the clipboard is trimmed to the outermost blocks, so empty space around them does not add an offset
* rotate = rotate the copied blocks and entities in place by 90, 180, or 270 degrees before pasting. Rotations add up; run rotate with no value to see the current rotation
* paste = load the blocks, metadata, timers, and entities relative to your position
* save = save the selected blocks, their metadata and timers as .txt in replace_data
* load = load a saved slot at pos1
* undo = undo last action
* redo = redo last action after being undone

Pull requests and comments welcome. This mod was made with the assistance of AI.
