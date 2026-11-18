proc rx25_validate_real_mem_test_addr {raw_addr} {
    set raw_addr [string trim $raw_addr]
    if {![regexp -nocase {^(0x)?([0-9a-f]{1,16})$} $raw_addr -> prefix digits]} {
        error "address must be a 1..16 digit hexadecimal value"
    }
    set address [expr 0x$digits]
    if {$address == 0} {
        error "address must be nonzero"
    }
    if {($address & 15) != 0} {
        error "address must be 16-byte aligned"
    }
    if {($address & 4095) > 4080} {
        error "16B request must stay within one 4KiB page"
    }
    return [list $address [format "64'h%016llX" $address]]
}
