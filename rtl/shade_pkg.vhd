-- shade_pkg.vhd : depth-cue shading for the E5 slot (Integration 3, MVP)
--
-- depth_cue(color, z): darken an RGB332 color by its fragment depth.
--   z8 = top 8 bits of z (z itself when DEPTH_W = 8; zero-extended when < 8)
--   k  = 256 - (z8 >> 1)                      256 at z8 = 0, 129 at z8 = 255
--   each field f (R 3 bits, G 3 bits, B 2 bits): f' = (f * k) >> 8
-- Brightness runs from 100 % at depth 0 to ~50 % at depth 255, so far
-- geometry stays visible against the black clear colour.
--   z = 54  -> k = 229 -> red 7 -> 6 -> x"C0"   (MVP face 12)
--   z = 201 -> k = 156 -> red 7 -> 4 -> x"80"   (MVP face 1)
-- Bit-exact rule: record it in docs/architecture/spec/qogpu_numeric_contract.md
-- so the Ada reference can match it.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;

package shade_pkg is
  function depth_cue(color : pixel_t; z : unsigned) return pixel_t;
end package;

package body shade_pkg is
  function depth_cue(color : pixel_t; z : unsigned) return pixel_t is
    variable z8 : unsigned(7 downto 0);
    variable k  : unsigned(8 downto 0);
    variable r  : unsigned(11 downto 0);
    variable g  : unsigned(11 downto 0);
    variable b  : unsigned(10 downto 0);
  begin
    if z'length >= 8 then
      z8 := z(z'left downto z'left - 7);
    else
      z8 := resize(z, 8);
    end if;
    k := to_unsigned(256, 9) - resize(z8(7 downto 1), 9);
    r := unsigned(color(7 downto 5)) * k;
    g := unsigned(color(4 downto 2)) * k;
    b := unsigned(color(1 downto 0)) * k;
    return std_logic_vector(r(10 downto 8)) & std_logic_vector(g(10 downto 8))
         & std_logic_vector(b(9 downto 8));
  end function;
end package body;
