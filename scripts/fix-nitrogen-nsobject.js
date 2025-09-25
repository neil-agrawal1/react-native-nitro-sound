// scripts/fix-nitrogen-nsobject.js
const fs = require('fs');
const path = require('path');

// Path to the generated file that needs fixing (relative to this script)
const filePath = path.join(
  __dirname,
  '../nitrogen/generated/ios/swift/HybridSoundSpec.swift'
);

try {
  // Check if file exists
  if (!fs.existsSync(filePath)) {
    console.log('⚠️  HybridSoundSpec.swift not found - might not be generated yet');
    process.exit(0);
  }

  // Read the current file
  let content = fs.readFileSync(filePath, 'utf8');

  // Check if fixes are already applied
  if (content.includes('HybridSoundSpec_base: NSObject')) {
    console.log('✅ NSObject inheritance already fixed');
    process.exit(0);
  }

  // Apply the fixes
  content = content.replace(
    'open class HybridSoundSpec_base {',
    'open class HybridSoundSpec_base: NSObject {'
  );

  content = content.replace(
    'public init() { }',
    'public override init() { super.init() }'
  );

  // Write the fixed content back
  fs.writeFileSync(filePath, content);

  console.log('✅ Fixed NSObject inheritance in HybridSoundSpec.swift');
  console.log('   - Added NSObject inheritance to HybridSoundSpec_base');
  console.log('   - Fixed init() to call super.init()');

} catch (error) {
  console.error('❌ Error fixing NSObject inheritance:', error.message);
  process.exit(1);
}