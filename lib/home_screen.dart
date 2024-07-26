import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ocr_scanner/image_preview.dart';
// import 'package:pdf_text/pdf_text.dart';
// import 'package:pdfx/pdfx.dart';
import 'package:path_provider/path_provider.dart';
// import 'package:pdfrx/pdfrx.dart' as pdf_render;
import 'package:pdf_image_renderer/pdf_image_renderer.dart';
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver  {
  late TextRecognizer textRecognizer;
  late ImagePicker imagePicker;

  List<String> pickedImagePaths = [];
  String recognizedText = "";
  String importantInformation = "";

  bool isRecognizing = false;

  @override
  void initState() {
    super.initState();

    textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    imagePicker = ImagePicker();
    WidgetsBinding.instance.addObserver(this);
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clearTempFiles();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached || state == AppLifecycleState.inactive) {
      _clearTempFiles();
    }
  }
  Future<void> _clearTempFiles() async {
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
      await _processImage(path);
    }
  }

  void extractReceiptInformation(String text) {
    debugPrint('Extracting receipt information');
    debugPrint("Text: $text");
    importantInformation = "";

    // Combine lines that should be together
    text = text.replaceAll('\n\n', '\n').replaceAll(' \n', ' ').replaceAll('\n ', ' ');

    // Define refined regex patterns
    RegExp datePattern = RegExp(r'\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b');
    RegExp amountPattern = RegExp(r'\b\d{1,3}(?:,\d{3})*(?:\.\d{2})?\b');
    RegExp itemPattern = RegExp(r'\b\d+\s+\w+.*?\s+\$\d+\.\d{2}\b');
    RegExp addressPattern = RegExp(r'\d+\s+\w+(\s+\w+)+,\s*\w+,\s*\w{2}\s*\d{5}');
    RegExp emailPattern = RegExp(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b');
    RegExp phonePattern = RegExp(r'\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}|\d{3}\s+\d{3}\s+\d{4}');

    // Find all matches
    Iterable<Match> dates = datePattern.allMatches(text);
    Iterable<Match> amounts = amountPattern.allMatches(text);
    Iterable<Match> items = itemPattern.allMatches(text);
    Iterable<Match> addresses = addressPattern.allMatches(text);
    Iterable<Match> emails = emailPattern.allMatches(text);
    Iterable<Match> phones = phonePattern.allMatches(text);

    // Extract matched values
    List<String> extractedDates = dates.map((match) => match.group(0)!).toList();
    List<String> extractedAmounts = amounts.map((match) => match.group(0)!).toList();
    List<String> extractedItems = items.map((match) => match.group(0)!).toList();
    List<String> extractedAddresses = addresses.map((match) => match.group(0)!).toList();
    List<String> extractedEmails = emails.map((match) => match.group(0)!).toList();
    List<String> extractedPhones = phones.map((match) => match.group(0)!).toList();

    // Create the extracted information string
    String extractedInformation = 'Extracted Dates: $extractedDates\n'
        'Extracted Amounts: $extractedAmounts\n'
        'Extracted Items: $extractedItems\n'
        'Extracted Addresses: $extractedAddresses\n'
        'Extracted Emails: $extractedEmails\n'
        'Extracted Phones: $extractedPhones\n';
    debugPrint(extractedInformation);
    importantInformation = extractedInformation;
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

          // create the temp image file
          final tempFile = File("${tempDir.path}/temp_${DateTime.now().millisecondsSinceEpoch}.jpg");
          await tempFile.writeAsBytes(image);

          // process the image
          final inputImage = InputImage.fromFilePath(tempFile.path);
          pickedImagePaths.add(tempFile.path);
          final RecognizedText recognisedText = await textRecognizer.processImage(inputImage);
          //tempFile.delete();
          for (TextBlock block in recognisedText.blocks) {
            // debugPrint("Block: ${block.text}");
            for (TextLine line in block.lines) {
              recognizedText += "${line.text}\n";
            }
          }
        }
      //}


      textRecognizer.close();
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
    } finally {
      setState(() {
        isRecognizing = false;
      });
    }
  }

  Future<void> _processImage(String path) async {
    setState(() {
      pickedImagePaths = [path];
      isRecognizing = true;
    });


    try {
      final inputImage = InputImage.fromFilePath(path);
      final RecognizedText recognisedText = await textRecognizer.processImage(inputImage);

      recognizedText = "";
      importantInformation = "";

      for (TextBlock block in recognisedText.blocks) {
        for (TextLine line in block.lines) {
          recognizedText += "${line.text}\n";
        }
      }

      // Replace multiple spaces with a single space
      // recognizedText = recognizedText.replaceAll(RegExp(r'\s+'), ' ');
    } catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error recognizing text: $e'),
        ),
      );
    } finally {
      setState(() {
        isRecognizing = false;
      });
    }
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
              child: ImagePreview(imagePaths: pickedImagePaths),
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
                  child: SingleChildScrollView(
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
            if (!isRecognizing && recognizedText.isNotEmpty && importantInformation.isNotEmpty) ...[
              ElevatedButton(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) {
                      return AlertDialog(
                        title: const Text('Important Information'),
                        content: Text(importantInformation),
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
