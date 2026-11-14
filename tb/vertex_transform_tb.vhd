-- Block C integration tests with an independent fixed-point arithmetic model.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;

entity vertex_transform_tb is end entity;
architecture sim of vertex_transform_tb is
  subtype q_t is signed(31 downto 0);
  type values_t is array(natural range <>) of q_t;
  constant IDENTITY : values_t(0 to 5) :=
    (to_signed(65536,32), to_signed(0,32), to_signed(65536,32),
     to_signed(0,32), to_signed(65536,32), to_signed(0,32));
  signal clk : std_logic := '0';
  signal rstn, iv, ov8, ov16, ir8, ir16, ready : std_logic := '0';
  signal x,y,z : q_t := (others => '0');
  signal coeff : values_t(0 to 5) := IDENTITY;
  signal id : unsigned(31 downto 0) := (others => '0');
  signal last : std_logic := '0';
  signal ox8,oy8,ox16,oy16 : q_t;
  signal oz8 : unsigned(7 downto 0);
  signal oz16 : unsigned(15 downto 0);
  signal oid8,oid16 : unsigned(31 downto 0);
  signal ol8,ol16 : std_logic;

  function q(value : integer) return q_t is
  begin return to_signed(value,32); end;
  function quantize(value : real) return q_t is
  begin return q(integer(floor(value*65536.0+0.5))); end;
  function angles(ax,ay,az : real) return values_t is
  begin
    return values_t'(quantize(cos(ax)),quantize(sin(ax)),
                    quantize(cos(ay)),quantize(sin(ay)),
                    quantize(cos(az)),quantize(sin(az)));
  end;
  -- Do not use qogpu_fx_pkg functions to calculate expected results.
  function product(a,b : q_t) return q_t is
    variable p : signed(63 downto 0);
  begin
    p := shift_right(a*b+to_signed(32768,64),16);
    assert resize(resize(p,32),64)=p report "Reference product overflow" severity failure;
    return resize(p,32);
  end;
  function rotate(v : values_t; c : values_t) return values_t is
    variable a,b : values_t(0 to 2);
  begin
    a(0):=v(0);
    a(1):=product(v(1),c(0))-product(v(2),c(1));
    a(2):=product(v(1),c(1))+product(v(2),c(0));
    b(0):=product(a(0),c(2))+product(a(2),c(3));
    b(1):=a(1);
    b(2):=product(a(2),c(2))-product(a(0),c(3));
    a(0):=product(b(0),c(4))-product(b(1),c(5));
    a(1):=product(b(0),c(5))+product(b(1),c(4));
    a(2):=b(2);
    return a;
  end;
  function depth(v : q_t; width : positive) return unsigned is
    variable p : signed(63 downto 0);
  begin
    p := (v+q(65536))*q(2**width-1)+to_signed(65536,64);
    return resize(unsigned(shift_right(p,17)),width);
  end;
begin
  clk <= not clk after 5 ns;
  lane8 : entity work.vertex_transform
    generic map(DEPTH_W=>8)
    port map(clk_i=>clk,rstn_i=>rstn,in_valid_i=>iv,in_ready_o=>ir8,
      in_x_i=>x,in_y_i=>y,in_z_i=>z,in_id_i=>id,in_last_i=>last,
      cos_x_i=>coeff(0),sin_x_i=>coeff(1),cos_y_i=>coeff(2),
      sin_y_i=>coeff(3),cos_z_i=>coeff(4),sin_z_i=>coeff(5),
      out_valid_o=>ov8,out_ready_i=>ready,out_x_o=>ox8,out_y_o=>oy8,
      out_z_o=>oz8,out_id_o=>oid8,out_last_o=>ol8);
  lane16 : entity work.vertex_transform
    generic map(DEPTH_W=>16)
    port map(clk_i=>clk,rstn_i=>rstn,in_valid_i=>iv,in_ready_o=>ir16,
      in_x_i=>x,in_y_i=>y,in_z_i=>z,in_id_i=>id,in_last_i=>last,
      cos_x_i=>coeff(0),sin_x_i=>coeff(1),cos_y_i=>coeff(2),
      sin_y_i=>coeff(3),cos_z_i=>coeff(4),sin_z_i=>coeff(5),
      out_valid_o=>ov16,out_ready_i=>ready,out_x_o=>ox16,out_y_o=>oy16,
      out_z_o=>oz16,out_id_o=>oid16,out_last_o=>ol16);

  stimulus : process
    variable tested : natural := 0;
    procedure tick is
    begin wait until rising_edge(clk); wait for 1 ns; end;
    procedure await_ready is
    begin
      for cycle in 1 to 10 loop
        exit when ir8='1' and ir16='1';
        assert ov8='0' and ov16='0'
          report "Stale output after reset or completed transaction" severity failure;
        tick;
      end loop;
      assert ir8='1' and ir16='1' report "Input ready timeout" severity failure;
    end;
    procedure reset_dut is
    begin
      rstn<='0';iv<='0';ready<='0';tick;
      assert ir8='0' and ir16='0' and ov8='0' and ov16='0'
        report "Reset must suppress ready and valid" severity failure;
      assert ox8=q(0) and oy8=q(0) and oz8=0 and oid8=0 and ol8='0'
        and ox16=q(0) and oy16=q(0) and oz16=0 and oid16=0 and ol16='0'
        report "Reset did not clear outputs" severity failure;
      rstn<='1';await_ready;
    end;
    procedure run_vertex(v : values_t; c : values_t; stalls : natural) is
      variable r : values_t(0 to 2);
      variable expected_id : unsigned(31 downto 0);
      variable expected_last : std_logic;
      procedure check_output is
      begin
        assert ov8='1' and ov16='1' report "Missing output valid" severity failure;
        assert ox8=q((to_integer(r(0))+65536)*160)
          and oy8=q((65536-to_integer(r(1)))*120)
          and ox16=ox8 and oy16=oy8
          report "Screen XY mismatch in case " & integer'image(tested) severity failure;
        assert oz8=depth(r(2),8) and oz16=depth(r(2),16)
          report "Depth mismatch in case " & integer'image(tested) severity failure;
        assert oid8=expected_id and oid16=expected_id
          and ol8=expected_last and ol16=expected_last
          report "Metadata mismatch" severity failure;
      end;
    begin
      await_ready;
      tested:=tested+1;
      expected_id:=to_unsigned(tested,32);
      if tested mod 2=0 then expected_last:='1'; else expected_last:='0'; end if;
      r:=rotate(v,c);
      x<=v(0);y<=v(1);z<=v(2);coeff<=c;
      id<=expected_id;last<=expected_last;iv<='1';
      if stalls=0 then ready<='1'; else ready<='0'; end if;
      tick;iv<='0';
      assert ir8='0' and ir16='0' report "Lane accepted overlapping work" severity failure;
      -- Change every input after acceptance: computation must use its snapshot.
      x<=q(123);y<=q(-456);z<=q(789);coeff<=(others=>q(0));
      id<=(others=>'1');last<=not expected_last;
      for cycle in 1 to 100 loop
        exit when ov8='1' or ov16='1';
        assert ir8='0' and ir16='0' report "Ready before operation completed" severity failure;
        tick;
      end loop;
      check_output;
      for cycle in 1 to stalls loop
        -- A busy source attempt must not overwrite the pending output.
        iv<='1';tick;iv<='0';
        check_output;
        assert ir8='0' and ir16='0' report "Input accepted during output stall" severity failure;
      end loop;
      ready<='1';tick;
      assert ov8='0' and ov16='0' and ir8='1' and ir16='1'
        report "Output handshake did not retire the result" severity failure;
      for cycle in 1 to 3 loop
        tick;
        assert ov8='0' and ov16='0' report "Duplicated output" severity failure;
      end loop;
    end;
    variable c : values_t(0 to 5);
    variable v : values_t(0 to 2);
  begin
    reset_dut;
    run_vertex(values_t'(q(0),q(0),q(0)),IDENTITY,0);
    run_vertex(values_t'(q(-65536),q(65536),q(-65536)),IDENTITY,3);
    run_vertex(values_t'(q(65536),q(-65536),q(65536)),IDENTITY,0);
    run_vertex(values_t'(q(32768),q(-16384),q(-1)),IDENTITY,2);
    for axis in 0 to 2 loop
      c:=IDENTITY;c(2*axis):=q(0);c(2*axis+1):=q(65536);
      v:=(q(8192),q(16384),q(-32768));
      run_vertex(v,c,axis+1);
      c(2*axis+1):=q(-65536);
      run_vertex(v,c,0);
    end loop;
    report "Identity, viewport/depth endpoints, and individual +/-90 degree rotations passed";
    -- Quantized sin/cos with asymmetric angles exercises order and rounding.
    c:=angles(0.31,-0.47,0.83);
    for corner in 0 to 7 loop
      for axis in 0 to 2 loop
        if (corner / (2**axis)) mod 2=0 then v(axis):=q(37837);
        else v(axis):=q(-37837); end if;
      end loop;
      run_vertex(v,c,corner mod 4);
    end loop;
    report "Combined rotations of normalized cube corners passed";
    -- Reset with products at several different in-flight positions.
    for delay in 1 to 9 loop
      await_ready;
      iv<='1';x<=q(10000);y<=q(-20000);z<=q(30000);coeff<=IDENTITY;
      tick;iv<='0';
      for cycle in 1 to delay loop tick; end loop;
      reset_dut;
      run_vertex(values_t'(q(16384),q(-8192),q(32768)),IDENTITY,0);
    end loop;
    report "Mid-calculation reset, pipeline flush, and recovery passed";
    -- Reset while a completed output is stalled.
    iv<='1';x<=q(0);y<=q(0);z<=q(0);coeff<=IDENTITY;ready<='0';
    tick;iv<='0';
    for cycle in 1 to 100 loop exit when ov8='1';tick;end loop;
    assert ov8='1' and ov16='1' report "No stalled result before reset" severity failure;
    reset_dut;
    run_vertex(values_t'(q(0),q(0),q(0)),IDENTITY,4);
    report "vertex_transform_tb: " & integer'image(tested) &
      " vertices checked at both 8-bit and 16-bit depth";
    report "vertex_transform_tb: ALL TESTS PASSED";
    finish(0);wait;
  end process;
  watchdog : process
  begin
    wait for 100 us;
    assert false report "vertex_transform_tb: global timeout" severity failure;
    wait;
  end process;
end architecture sim;
