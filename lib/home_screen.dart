import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ocr_scanner/image_preview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf_image_renderer/pdf_image_renderer.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'dart:isolate';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late TextRecognizer textRecognizer;
  late ImagePicker imagePicker;
  static const platform = MethodChannel('com.example.ocr_scanner/preprocess');
  List<String> pickedImagePaths = [];
  String recognizedText = "";
  String importantInformation = "";

  bool isRecognizing = false;
  final ScrollController _scrollController = ScrollController();
  @override
  void initState() {
    super.initState();
    textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    imagePicker = ImagePicker();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _clearTempFiles();
    textRecognizer.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached || state == AppLifecycleState.inactive) {
      _clearTempFiles();
    }
  }

  Future<void> _clearTempFiles() async {
    pickedImagePaths = [];
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final Directory tempDir = Directory('${appDocDir.path}/temp_images');
    if (await tempDir.exists()) {
      tempDir.deleteSync(recursive: true);
    }
  }

  void _pickImageAndProcess({required ImageSource? source, bool isFile = false, bool isPdf = false}) async {
    String? path;

    if (isFile) {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: isPdf ? ['pdf'] : ['jpg', 'jpeg', 'png', 'bmp', 'gif', 'webp', 'heic'],
      );
      if (result != null && result.files.single.path != null) {
        path = result.files.single.path;
      }
    } else {
      final pickedImage = await imagePicker.pickImage(source: source!);
      path = pickedImage?.path;
    }

    if (path == null) {
      return;
    }

    if (isPdf) {
      await _processPdf(path);
    } else {
      await _processDirectImage(path);
    }

  }
  Future<List<Uint8List>> renderPages(String path) async {
    List<Uint8List> images = [];
    PdfImageRendererPdf? pdf;

    try {
      pdf = PdfImageRendererPdf(path: path);
      await pdf.open();
    } catch (e) {
      debugPrint("Failed to open PDF: $e");
      return images;
    }

    try {
      int? pages = await pdf.getPageCount();
      debugPrint("Number of pages: $pages");

      for (int i = 0; i < pages!; i++) {
        try {
          await pdf.openPage(pageIndex: i);
          PdfImageRendererPageSize? size = await pdf.getPageSize(pageIndex: i);
          int x = 0;
          int y = 0;
          int width = size?.width ?? 1000;
          int height = size?.height ?? 1000;
          Uint8List? image = await pdf.renderPage(
            pageIndex: i,
            x: x,
            y: y,
            width: width,
            height: height,
            scale: 3,
            background: Colors.white,
          );

          if (image != null) {
            images.add(image);
          }

          await pdf.closePage(pageIndex: i);
        } catch (e) {
          debugPrint("Error rendering page $i: $e");
        }
      }
    } finally {
      await pdf.close();
    }

    return images;
  }


  Future<void> _processPdf(String path) async {
    setState(() {
      pickedImagePaths = [];
      isRecognizing = true;
    });

    try {
      recognizedText = "";
      importantInformation = "";

      List<Uint8List> images = await renderPages(path);
      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final Directory tempDir = Directory('${appDocDir.path}/temp_images');
      if (!await tempDir.exists()) {
        await tempDir.create();
      }
      for (Uint8List image in images) {
        final tempFile = File("${tempDir.path}/temp_${DateTime.now().millisecondsSinceEpoch}.jpg");
        await tempFile.writeAsBytes(image);
        pickedImagePaths.add(tempFile.path);
        await _processImage(tempFile.path);
      }
    } catch (e) {
      debugPrint('Error extracting text from PDF: $e');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error extracting text from PDF: $e'),
        ),
      );
    }
  }

  Future<void> _processDirectImage(String path) async {
    setState(() {
      pickedImagePaths = [path];
      isRecognizing = true;
    });
    recognizedText = "";

    try {
      await _processImage(path);
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error recognizing text: $e'),
        ),
      );
    }
  }

  Future<void> _processImage(String path) async {
    setState(() {
      isRecognizing = true;
    });

    try {
      // Read the image file into a Uint8List
      Uint8List imageBytes = await File(path).readAsBytes();

      // Use the heavyTask function to process the image in an isolate
      final (Uint8List grayImageBytes, Uint8List blurImageBytes, Uint8List adaptiveThresholdBytes) = await heavyTask(imageBytes);

      // Save the processed images if needed
      final Directory tempDir = await getTemporaryDirectory();
      String grayImagePath = '${tempDir.path}/gray_image.png';
      String adaptiveThresholdPath = '${tempDir.path}/adaptive_threshold.png';

      // Write the processed grayscale image to a file
      await File(grayImagePath).writeAsBytes(grayImageBytes);
      await File(adaptiveThresholdPath).writeAsBytes(adaptiveThresholdBytes);

      // _processAndGetText(path);
      // _processAndGetText(adaptiveThresholdPath);
      _processAndGetText(grayImagePath);


    } catch (e) {
      debugPrint("Error processing image: $e");
      setState(() {
        isRecognizing = false;
      });
    }
  }

Future<void> _processAndGetText(String imagePath) async {
  final InputImage inputImage = InputImage.fromFilePath(imagePath);
  final RecognizedText recognizedTextResult = await textRecognizer.processImage(inputImage);

  setState(() {
    String tempRecognizedText = "";
    // check how many blocks are there
    debugPrint("Number of blocks: ${recognizedTextResult.blocks.length}");
    // loop through the blocks
    for (TextBlock block in recognizedTextResult.blocks) {
      // Print the text in this block
      debugPrint("Block text: ${block.text}");
      for (TextLine line in block.lines) {
        tempRecognizedText += line.text + ' ';
      }
    }
    if (pickedImagePaths.contains(imagePath)) {
      return;
    }
    pickedImagePaths.add(imagePath);
    recognizedText = tempRecognizedText.replaceAll(RegExp(r'\s{2,}'), ' ').replaceAll(RegExp(r'\n{2,}'), '\n').trim();

    setState(() {
      isRecognizing = false;
    });
    extractReceiptInformation(recognizedText);
  });
}
  Future<(Uint8List, Uint8List, Uint8List)> heavyTask(Uint8List buffer) async {
    return await Isolate.run(() {
      final im = cv.imdecode(buffer, cv.IMREAD_COLOR);

      // Convert to grayscale
      final gray = cv.cvtColor(im, cv.COLOR_BGR2GRAY);

      // Apply Gaussian blur
      final blur = cv.gaussianBlur(gray, (7, 7), 2, sigmaY: 2);

      // Apply adaptive thresholding
      final adaptiveThreshold = cv.adaptiveThreshold(blur, 255, cv.ADAPTIVE_THRESH_GAUSSIAN_C, cv.THRESH_BINARY, 11, 2);

      return (
      cv.imencode(".png", gray).$2,
      cv.imencode(".png", blur).$2,
      cv.imencode(".png", adaptiveThreshold).$2
      );
    });
  }

  void _chooseImageSourceModal() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from gallery'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImageAndProcess(source: ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Take a picture'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImageAndProcess(source: ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.file_copy),
                title: const Text('Choose from files'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImageAndProcess(source: null, isFile: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf),
                title: const Text('Choose from PDF files'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImageAndProcess(source: null, isFile: true, isPdf: true);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _copyTextToClipboard() async {
    if (recognizedText.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: recognizedText));
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Text copied to clipboard'),
        ),
      );
    }
  }
 void extractReceiptInformation(String text) {
    debugPrint('Extracting receipt information');
    debugPrint("Text: $text");
    importantInformation = "";

    // Combine lines that should be together
    text = text.replaceAll('\n\n', '\n').replaceAll(' \n', ' ').replaceAll('\n ', ' ');

    // Define flexible regex patterns
    RegExp datePattern = RegExp(r'\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2},?\s+\d{4}\b');
    RegExp timePattern = RegExp(r'\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)?\b');
    RegExp amountPattern = RegExp(r'\b\d{1,3}(?:,\d{3})*(?:\.\d{2})?\b');
    RegExp itemPattern = RegExp(r'(\d+)\s+([\w\s]+)\s+([\d,]+\.\d{2})');
    RegExp totalPattern = RegExp(r'(?:Total|TOTAL|Sum|Amount|Total Price|CASH)\s*(\b\d{1,3}(?:[\s,]\d{3})*(?:\.\d{2})?\b)', caseSensitive: false);
    RegExp businessNamePattern = RegExp(r'^([A-Z\s&]+)$', multiLine: true);
    RegExp addressPattern = RegExp(r'\b\d+\s+[\w\s,]+\b');
    RegExp phonePattern = RegExp(r'\b\d{3}[-.]?\d{3}[-.]?\d{4}\b');
    RegExp orderNumberPattern = RegExp(r'(?:Order|Receipt|Transaction)(?:\s+#)?:\s*(\d+)', caseSensitive: false);
    RegExp serverPattern = RegExp(r'(?:Server|Cashier|Employee):\s*(\w+)', caseSensitive: false);

    // Find matches
    String? businessName = businessNamePattern.firstMatch(text)?.group(1);
    String? address = addressPattern.firstMatch(text)?.group(0);
    String? phone = phonePattern.firstMatch(text)?.group(0);
    String? date = datePattern.firstMatch(text)?.group(0);
    String? time = timePattern.firstMatch(text)?.group(0);
    String? orderNumber = orderNumberPattern.firstMatch(text)?.group(1);
    String? server = serverPattern.firstMatch(text)?.group(1);
    List<String> items = itemPattern.allMatches(text).map((m) => '${m.group(1)} ${m.group(2)} - ${m.group(3)}').toList();
    String? total = totalPattern.firstMatch(text)?.group(1);

    debugPrint("The total is $total");

    // If no specific total found, use the last amount as potential total
   if (total == null) {
        RegExp amountPattern = RegExp(r'\b\d{1,3}(?:[\s,]\d{3})*(?:\.\d{2})?\b');
        List<String> allAmounts = amountPattern.allMatches(text).map((m) => m.group(0)!).toList();
        debugPrint("All amounts: $allAmounts");
        List<double> validAmounts = allAmounts
            .where((amount) => amount.contains('.'))
            .map((amount) => double.parse(amount.replaceAll(',', '').replaceAll(' ', '')))
            .toList();
        validAmounts.sort();
        if (validAmounts.isNotEmpty) {
          total = validAmounts.last.toStringAsFixed(2);
        }
        // Print the extracted total amount
        debugPrint('Total Amount: $total');
      }

    // Create the extracted information string
    String extractedInformation = 'Business Name: $businessName\n'
        'Address: $address\n'
        'Phone: $phone\n'
        'Date: $date\n'
        'Time: $time\n'
        'Order Number: $orderNumber\n'
        'Server: $server\n'
        'Items:\n${items.join('\n')}\n'
        'Total: $total\n';

    debugPrint(extractedInformation);
    importantInformation = extractedInformation;
}
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ML Text Recognition'),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ImagePreview(imagePaths: pickedImagePaths, focusOnImage: (imagePath) {
                _processAndGetText(imagePath);
                // popup the current path
                showDialog(
                  context: context,
                  builder: (context) {
                    return AlertDialog(
                      title: const Text('Current Image Path'),
                      content: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Image.file(
                          File(imagePath),
                          fit: BoxFit.contain,
                        ),
                      ),
                      actions: <Widget>[
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                          },
                          child: const Text('Close'),
                        ),
                      ],
                    );
                  },
                );
              }),
            ),
            ElevatedButton(
              onPressed: isRecognizing ? null : _chooseImageSourceModal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Pick an image or PDF'),
                  if (isRecognizing) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: 16,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "Recognized Text",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.copy,
                      size: 16,
                    ),
                    onPressed: _copyTextToClipboard,
                  ),
                ],
              ),
            ),
            if (!isRecognizing) ...[
              Expanded(
                child: Scrollbar(
                  controller: _scrollController,
                  child: SingleChildScrollView(
                     controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Flexible(
                          child: SelectableText(
                            recognizedText.isEmpty
                                ? "No text recognized"
                                : recognizedText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            if (!isRecognizing && recognizedText.isNotEmpty && importantInformation.isEmpty ) ...[
              ElevatedButton(
                onPressed: () {
                  extractReceiptInformation(recognizedText);
                },
                child: recognizedText.isNotEmpty ? const Text('Extract Receipt Information') : null,
              ),
            ],
            if (!isRecognizing && importantInformation.isNotEmpty) ...[
              ElevatedButton(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) {
                      return AlertDialog(
                        title: const Text('Important Information'),
                    content: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(recognizedText),
                            const SizedBox(height: 16),
                            // Draw a horizontal line
                            Container(
                              height: 1,
                              color: Colors.grey,
                              margin: const EdgeInsets.symmetric(vertical: 8),
                            ),
                            SelectableText(importantInformation, style: const TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                        actions: <Widget>[
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                            },
                            child: const Text('Close'),
                          ),
                        ],
                      );
                    },
                  );
                },
                child: importantInformation.isNotEmpty ? const Text('Show Extracted Information') : null,
              ),
            ]
          ],
        ),
      ),
    );
  }
}