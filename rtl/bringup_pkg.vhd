-- Bring-up test data shared by gpu_top (stimulus sequencer) and gpu_top_tb
-- (expected frame). Integration 1 only: goes away with the sequencer in
-- Integration 2.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;

package bringup_pkg is
  constant BRINGUP_DEPTH_W : positive := 8;
  constant BRINGUP_COLOR   : pixel_t := x"03";   -- blue background

  -- test pixels written through E6 (corners and middle)
  constant N_TEST_PIX : positive := 6;
  type nat_arr_t is array (0 to N_TEST_PIX - 1) of natural;
  type pix_arr_t is array (0 to N_TEST_PIX - 1) of pixel_t;
  constant TEST_X     : nat_arr_t := (0, 319, 0, 319, 160, 161);
  constant TEST_Y     : nat_arr_t := (0, 0, 239, 239, 120, 120);
  constant TEST_Z     : nat_arr_t := (16, 32, 48, 64, 80, 96);
  constant TEST_COLOR : pix_arr_t := (x"E0", x"1C", x"FF", x"FC", x"FF", x"E0");

  -- depth readback list: 3 untouched words (must still hold the clear value),
  -- then the test pixels (must hold their z)
  constant N_DEPTH_CHECKS : positive := 3 + N_TEST_PIX;

  function bringup_expected(x, y : natural) return pixel_t;
  function depth_check_addr(k : natural) return natural;
  function depth_check_exp(k : natural) return std_logic_vector;
end package;

package body bringup_pkg is
  function bringup_expected(x, y : natural) return pixel_t is
  begin
    for i in 0 to N_TEST_PIX - 1 loop
      if x = TEST_X(i) and y = TEST_Y(i) then
        return TEST_COLOR(i);
      end if;
    end loop;
    return BRINGUP_COLOR;
  end function;

  function depth_check_addr(k : natural) return natural is
  begin
    case k is
      when 0 => return 1;
      when 1 => return 38401;
      when 2 => return 76798;
      when others => return TEST_Y(k - 3) * FB_W + TEST_X(k - 3);
    end case;
  end function;

  function depth_check_exp(k : natural) return std_logic_vector is
  begin
    if k < 3 then
      return std_logic_vector(to_unsigned(2 ** BRINGUP_DEPTH_W - 1, BRINGUP_DEPTH_W));
    else
      return std_logic_vector(to_unsigned(TEST_Z(k - 3), BRINGUP_DEPTH_W));
    end if;
  end function;
end package body;