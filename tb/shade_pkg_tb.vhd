-- shade_pkg_tb: depth_cue against the table in the Integration 3 plan.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;
use work.shade_pkg.all;

entity shade_pkg_tb is
end entity;

architecture sim of shade_pkg_tb is
begin
  process
    variable errors : natural := 0;
    procedure check(c : pixel_t; z : natural; exp : pixel_t) is
      variable got : pixel_t;
    begin
      got := depth_cue(c, to_unsigned(z, 8));
      if got /= exp then
        report "depth_cue(" & to_hstring(c) & ", " & integer'image(z) & ") = " &
               to_hstring(got) & ", expected " & to_hstring(exp) severity error;
        errors := errors + 1;
      end if;
    end procedure;
  begin
    check(x"E0",   0, x"E0");   -- k = 256
    check(x"E0",  54, x"C0");   -- face 12
    check(x"E0", 201, x"80");   -- face 1
    check(x"E0", 255, x"60");   -- k = 129
    check(x"1C", 128, x"14");   -- green 7 * 192 >> 8 = 5
    check(x"03", 128, x"02");   -- blue  3 * 192 >> 8 = 2
    check(x"FF",   0, x"FF");
    check(x"00", 100, x"00");
    if errors = 0 then
      report "shade_pkg_tb: ALL TESTS PASSED";
    else
      report "FAIL: errors=" & integer'image(errors) severity failure;
    end if;
    wait;
  end process;
end architecture;
