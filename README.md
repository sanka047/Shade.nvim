# shade.nvim

Shade is a Neovim plugin that dims your inactive windows, making it easier to see the active window
at a glance.

<img src="https://raw.githubusercontent.com/sunjon/images/master/shade_demo.gif" alt="screenshot" width="800"/>

## Installation

### [Packer](https://github.com/wbthomason/packer.nvim) 

```
use 'sunjon/shade.nvim'
```
### [Vim-Plug](https://github.com/junegunn/vim-plug)

```
Plug 'sunjon/shade.nvim'
```

## Configuration

NOTE: Ensure that Shade's `zindex` value is configured to be lower than any other plugins that you
would prefer to be shown higher than the floating windows Shade creates to dim your inactive splits.
For example, these plugins could clash (see [this issue](https://github.com/b0o/incline.nvim/issues/17)):
- [treesitter-context](https://github.com/nvim-treesitter/nvim-treesitter-context)
- [incline.nvim](https://github.com/b0o/incline.nvim/)

```
require'shade'.setup({
  overlay_opacity = 50,
  opacity_step = 1,
  keys = {
    brightness_up    = '<C-Up>',
    brightness_down  = '<C-Down>',
    toggle           = '<Leader>s',
  },
  shade_zindex = 1,
})
```

* The `keys` table above shows available actions. No mappings are defined by default.

* The color of the numbers in the brightness control popup can be customized by creating a highlight
  group named: `ShadeBrightnessPopup` and setting the attributes to your liking.

## License

Copyright (c) Senghan Bright. Distributed under the MIT license

