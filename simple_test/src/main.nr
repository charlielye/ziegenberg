// Simple test for breakpoint functionality
// Using unconstrained to force Brillig compilation

unconstrained fn compute(x: u32, y: u32) -> u32 {
    // Line 5: First computation
    let mut result = x + y;
    
    // Line 8: Double the result  
    result = result * 2;
    
    // Line 11: Add 10
    result = result + 10;
    
    // Line 14: Final computation
    result = result - 5;
    
    // Line 17: Return
    result
}

fn main(x: u32, y: u32) -> pub u32 {
    // Call the unconstrained function
    let result = unsafe { compute(x, y) };
    result
}